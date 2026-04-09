import Foundation
import CommonCrypto
import AppKit
import Security

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

        var components = URLComponents(string: Self.authorizeURL)!
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
            saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt)
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

        if let expiresAt = loadExpiresAt(), Date.now.timeIntervalSince1970 > (expiresAt - 300) {
            guard let rt = loadRefreshToken(), !rt.isEmpty else {
                logoutReason = "noToken"
                logout()
                return nil
            }

            if pendingRefresh == nil {
                pendingRefresh = Task {
                    try await refreshAccessToken(refreshToken: rt)
                }
            }

            do {
                let tokens = try await pendingRefresh!.value
                pendingRefresh = nil
                saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt)
                return tokens.accessToken
            } catch {
                // #5: Catch all errors (including CancellationError), not just NSError
                pendingRefresh = nil

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
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
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

        let newRefreshToken = (json["refresh_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            ?? loadRefreshToken() ?? ""
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
                    sleepDuration = max(60, timeUntilExpiry - 300)  // refresh 5min before expiry, min 60s
                } else {
                    sleepDuration = 1800
                }
                try? await Task.sleep(for: .seconds(sleepDuration))
                guard !Task.isCancelled else { break }
                if let rt = loadRefreshToken(), !rt.isEmpty {
                    if let tokens = try? await refreshAccessToken(refreshToken: rt) {
                        saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt)
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

    private func saveTokens(accessToken: String, refreshToken: String, expiresAt: Double) {
        saveToKeychain(key: Self.accessTokenKey, value: accessToken)
        saveToKeychain(key: Self.refreshTokenKey, value: refreshToken)
        saveToKeychain(key: Self.expiresAtKey, value: String(expiresAt))
    }

    func loadAccessToken() -> String? { loadFromKeychain(key: Self.accessTokenKey) }
    private func loadRefreshToken() -> String? { loadFromKeychain(key: Self.refreshTokenKey) }
    private func loadExpiresAt() -> Double? { loadFromKeychain(key: Self.expiresAtKey).flatMap(Double.init) }

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

    private func saveToKeychain(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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
