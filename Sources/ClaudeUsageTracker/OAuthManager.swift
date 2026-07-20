import Foundation
import CommonCrypto
import AppKit
import Security
import os.log

/// Manages OAuth 2.0 PKCE flow with Anthropic's authorization endpoint.
@MainActor
final class OAuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoggingIn = false
    @Published var loginError: String?
    @Published var logoutReason: String?  // nil, "sessionExpired", "noToken", "networkError", "keychainLocked"

    private static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = "https://claude.ai/oauth/authorize"
    private static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    private static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private static let scope = "org:create_api_key user:profile user:inference"

    private static let keychainService = "com.fiskaly.claude-usage-tracker.oauth"
    private static let accessTokenKey = "accessToken"
    private static let refreshTokenKey = "refreshToken"
    private static let expiresAtKey = "expiresAt"

    private static let log = Logger(subsystem: "com.beniamincostas.ClaudeUsageTracker", category: "OAuthManager")

    private var pkceVerifier: String?
    private var pkceState: String?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh: Task<TokenResponse, Error>?

    init() {
        if UserDefaults.standard.string(forKey: "authMethod") == "oauth" {
            isAuthenticated = true
        }
    }

    // MARK: - Public API

    func startLogin() {
        guard !isLoggingIn else { return }  // #9: prevent double-click
        isLoggingIn = true
        loginError = nil

        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateRandomState()

        pkceVerifier = verifier
        pkceState = state

        guard var components = URLComponents(string: Self.authorizeURL) else {
            loginError = "Configuration error: invalid authorize URL"
            isLoggingIn = false
            Self.log.error("authorizeURL is not a valid URLComponents string")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    func completeLogin(codeWithState: String) async {
        guard let verifier = pkceVerifier, let expectedState = pkceState else {
            loginError = "No login flow in progress. Click Login first."
            isLoggingIn = false
            return
        }

        let parts = codeWithState.trimmingCharacters(in: .whitespacesAndNewlines)

        // #4: Require code#state format — reject input without #
        guard let hashIndex = parts.firstIndex(of: "#") else {
            loginError = "Invalid format. Expected: code#state"
            return
        }

        let code = String(parts[parts.startIndex..<hashIndex])
        let state = String(parts[parts.index(after: hashIndex)...])

        guard state == expectedState else {
            loginError = "Security error: state mismatch. Please try again."
            pkceVerifier = nil
            pkceState = nil
            isLoggingIn = false
            return
        }

        do {
            let tokens = try await exchangeCode(code: code, state: state, verifier: verifier)
            let saveStatus = saveTokens(accessToken: tokens.accessToken,
                                        refreshToken: tokens.refreshToken,
                                        expiresAt: tokens.expiresAt)
            // #1: Surface keychain failure instead of pretending the user is logged in
            guard saveStatus == errSecSuccess else {
                Self.log.error("Keychain save failed during login (OSStatus \(saveStatus))")
                loginError = "Could not save credentials to Keychain (OSStatus \(saveStatus))"
                isLoggingIn = false
                isAuthenticated = false
                pkceVerifier = nil
                pkceState = nil
                return
            }
            isAuthenticated = true
            isLoggingIn = false
            loginError = nil
            logoutReason = nil
            pkceVerifier = nil
            pkceState = nil
            startTokenRefreshLoop()
        } catch {
            let msg = String(error.localizedDescription.prefix(200))
            loginError = "Login failed: \(msg)"
            // #9: Clear PKCE state so user must restart flow
            pkceVerifier = nil
            pkceState = nil
            isLoggingIn = false
        }
    }

    func getAccessToken() async -> String? {
        let (token, status) = loadAccessTokenWithStatus()

        // #8: Handle Keychain locked (sleep/wake)
        if status == errSecInteractionNotAllowed {
            logoutReason = "keychainLocked"
            return nil  // Don't logout — just wait for unlock
        }

        guard let token else {
            if isAuthenticated {
                logoutReason = "noToken"
                logout()
            }
            return nil
        }

        // Treat a nil expiresAt (missing / unparseable) as already-expired so we
        // refresh proactively rather than continuing to use a token whose expiry
        // we can no longer evaluate (issue #2).
        let storedExpiresAt = loadExpiresAt()
        let needsRefresh = storedExpiresAt.map { Date.now.timeIntervalSince1970 > ($0 - 300) } ?? true
        if needsRefresh {
            guard let rt = loadRefreshToken(), !rt.isEmpty else {
                logoutReason = "noToken"
                logout()
                return nil
            }

            // Dedupe concurrent refreshes: reuse the in-flight Task if present.
            // Only the *owning* caller (the one that started the Task) is
            // responsible for clearing pendingRefresh and persisting the result;
            // followers just await the value.
            let task: Task<TokenResponse, Error>
            let isOwner: Bool
            if let existing = pendingRefresh {
                task = existing
                isOwner = false
            } else {
                let new = Task { try await refreshAccessToken(refreshToken: rt) }
                pendingRefresh = new
                task = new
                isOwner = true
            }

            do {
                let tokens = try await task.value
                if isOwner {
                    pendingRefresh = nil
                    let saveStatus = saveTokens(accessToken: tokens.accessToken,
                                                refreshToken: tokens.refreshToken,
                                                expiresAt: tokens.expiresAt)
                    if saveStatus != errSecSuccess {
                        Self.log.error("Refreshed tokens failed to persist (OSStatus \(saveStatus))")
                        logoutReason = "keychainLocked"
                        return nil
                    }
                }
                // Recovered — clear any prior transient reason (keychainLocked /
                // networkError) so a stale value can't later masquerade as the cause
                // of an unrelated 401 in UsageViewModel's status handling.
                logoutReason = nil
                return tokens.accessToken
            } catch {
                // #5: Catch all errors (including CancellationError), not just NSError
                if isOwner { pendingRefresh = nil }

                // A cancellation (e.g. a concurrent logout cancelled the shared
                // refresh Task, or the app is tearing down) is NOT an auth failure.
                // Treat it as transient: keep tokens, don't force a logout, don't
                // set a misleading "sessionExpired" reason.
                if error is CancellationError {
                    return nil
                }

                // #7: Network errors — don't delete tokens, just return nil
                if (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain {
                    logoutReason = "networkError"
                    // Keep tokens — they may still be valid after network recovers
                    return nil
                }

                // Auth errors (401, invalid token) — session is truly expired
                logoutReason = "sessionExpired"
                logout()
                return nil
            }
        }

        // Valid unexpired token in hand — clear any prior transient reason so the
        // UI doesn't keep reporting a keychain-locked / network state after recovery.
        logoutReason = nil
        return token
    }

    // #6: logout clears authMethod to prevent stale state on next launch
    func logout() {
        deleteFromKeychain(key: Self.accessTokenKey)
        deleteFromKeychain(key: Self.refreshTokenKey)
        deleteFromKeychain(key: Self.expiresAtKey)
        UserDefaults.standard.removeObject(forKey: "authMethod")
        isAuthenticated = false
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    // MARK: - Token Exchange

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
    }

    private func exchangeCode(code: String, state: String, verifier: String) async throws -> TokenResponse {
        let body: [String: Any] = [
            "code": code, "state": state, "grant_type": "authorization_code",
            "client_id": Self.clientId, "redirect_uri": Self.redirectURI, "code_verifier": verifier,
        ]
        return try await postTokenRequest(body: body)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientId,
        ]
        return try await postTokenRequest(body: body)
    }

    private func postTokenRequest(body: [String: Any]) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenURL) else {
            throw NSError(domain: "OAuthError", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid token endpoint URL"
            ])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "OAuthError", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Token request failed (HTTP \(status))"
            ])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "OAuthError", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid token response"
            ])
        }

        // Prefer the server's refresh token; fall back to the stored one if the
        // response omits it (some refresh grants don't rotate it). If neither is
        // available, throw rather than persisting an empty string — an empty
        // refresh token would be saved and then trip the `!rt.isEmpty` guard on the
        // next refresh, turning a transient server quirk into a forced logout (#B5).
        let serverRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let newRefreshToken = serverRefresh ?? loadRefreshToken(), !newRefreshToken.isEmpty else {
            throw NSError(domain: "OAuthError", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Token response had no refresh token and none was stored"
            ])
        }
        let expiresIn = json["expires_in"] as? Double ?? 3600

        return TokenResponse(accessToken: accessToken, refreshToken: newRefreshToken,
                           expiresAt: Date.now.timeIntervalSince1970 + expiresIn)
    }

    // MARK: - Token Refresh Loop

    // #11: Sleep until actual expiry instead of fixed 30min
    private func startTokenRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                let sleepDuration: TimeInterval
                if let expiresAt = loadExpiresAt() {
                    let timeUntilExpiry = expiresAt - Date.now.timeIntervalSince1970
                    // Clamp to [60s, 1h]. The lower bound avoids a hot loop; the upper
                    // bound means a corrupt-but-finite far-future expiresAt (e.g. ms
                    // stored as s) can't park the refresh loop for years — it re-checks
                    // hourly and the on-demand path stays correct meanwhile.
                    sleepDuration = min(3600, max(60, timeUntilExpiry - 300))
                } else {
                    sleepDuration = 1800
                }
                try? await Task.sleep(for: .seconds(sleepDuration))
                guard !Task.isCancelled else { break }
                if let rt = loadRefreshToken(), !rt.isEmpty {
                    if let tokens = try? await refreshAccessToken(refreshToken: rt) {
                        let status = saveTokens(accessToken: tokens.accessToken,
                                                refreshToken: tokens.refreshToken,
                                                expiresAt: tokens.expiresAt)
                        if status != errSecSuccess {
                            Self.log.error("Background refresh failed to persist (OSStatus \(status))")
                        }
                    }
                }
            }
        }
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &hash) }
        return Data(hash).base64URLEncoded()
    }

    private func generateRandomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - Keychain

    /// Persist the three credential items. Returns `errSecSuccess` only if every
    /// `SecItemAdd` succeeded. Caller must treat any other return as a failed save.
    @discardableResult
    private func saveTokens(accessToken: String, refreshToken: String, expiresAt: Double) -> OSStatus {
        let s1 = saveToKeychain(key: Self.accessTokenKey, value: accessToken)
        let s2 = saveToKeychain(key: Self.refreshTokenKey, value: refreshToken)
        let s3 = saveToKeychain(key: Self.expiresAtKey, value: String(expiresAt))
        for status in [s1, s2, s3] where status != errSecSuccess { return status }
        return errSecSuccess
    }

    func loadAccessToken() -> String? { loadFromKeychain(key: Self.accessTokenKey) }
    private func loadRefreshToken() -> String? { loadFromKeychain(key: Self.refreshTokenKey) }

    /// Returns the stored expiry in seconds-since-epoch. If the item is missing or
    /// the persisted string can no longer be parsed (corruption, partial write),
    /// returns `nil` — callers must treat `nil` as "expired" and force a refresh
    /// rather than as "no expiry".
    private func loadExpiresAt() -> Double? {
        guard let raw = loadFromKeychain(key: Self.expiresAtKey) else { return nil }
        guard let parsed = Double(raw) else {
            Self.log.error("expiresAt keychain value could not be parsed; treating as expired")
            return nil
        }
        // Reject NaN / ±infinity — those propagate through the refresh-loop's
        // arithmetic and into `Task.sleep(for:)` with undefined behavior.
        guard parsed.isFinite else {
            Self.log.error("expiresAt is non-finite (nan/inf); treating as expired")
            return nil
        }
        return parsed
    }

    // #8: Return OSStatus for Keychain-locked detection
    private func loadAccessTokenWithStatus() -> (String?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.accessTokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    /// Replace the keychain item at `key` with `value`. Returns the `OSStatus`
    /// from `SecItemAdd` so callers can detect a locked / failed keychain.
    /// `SecItemDelete` is best-effort (errSecItemNotFound is fine on first save).
    private func saveToKeychain(key: String, value: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
