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
    @Published var logoutReason: String?  // nil, "sessionExpired", "noToken", "networkError"

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
    private var pendingRefresh: Task<TokenResponse, Error>?  // #3: refresh gate

    init() {
        // #9: Only set isAuthenticated as UI hint — actual token verified on first getAccessToken()
        if UserDefaults.standard.string(forKey: "authMethod") == "oauth" {
            isAuthenticated = true
        }
    }

    // MARK: - Public API

    func startLogin() {
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
        let code: String
        let state: String

        if let hashIndex = parts.firstIndex(of: "#") {
            code = String(parts[parts.startIndex..<hashIndex])
            state = String(parts[parts.index(after: hashIndex)...])
        } else {
            code = parts
            state = expectedState
        }

        guard state == expectedState else {
            loginError = "State mismatch. Try again."
            isLoggingIn = false
            debugLog("State mismatch: got=\(state) expected=\(expectedState)")
            return
        }

        debugLog("Exchanging code (\(code.prefix(20))...) with state (\(state.prefix(20))...)")

        do {
            let tokens = try await exchangeCode(code: code, state: state, verifier: verifier)
            debugLog("Token exchange succeeded, saving tokens")
            saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt)
            isAuthenticated = true
            isLoggingIn = false
            loginError = nil
            logoutReason = nil
            pkceVerifier = nil
            pkceState = nil
            startTokenRefreshLoop()
        } catch {
            let msg = error.localizedDescription
            debugLog("Token exchange FAILED: \(msg)")
            loginError = "Login failed: \(String(msg.prefix(300)))"
            // Stay on code input so user can retry
        }
    }

    // #3: Refresh gate — prevents concurrent refresh calls from racing
    func getAccessToken() async -> String? {
        guard let token = loadAccessToken() else {
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

            // Use pending refresh if one is already in flight
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
            } catch let error as NSError {
                pendingRefresh = nil
                logoutReason = error.domain == NSURLErrorDomain ? "networkError" : "sessionExpired"
                logout()
                return nil
            }
        }

        return token
    }

    func logout() {
        deleteFromKeychain(key: Self.accessTokenKey)
        deleteFromKeychain(key: Self.refreshTokenKey)
        deleteFromKeychain(key: Self.expiresAtKey)
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

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let respBody = String(data: data, encoding: .utf8) ?? ""
        debugLog("Token endpoint HTTP \(status): \(String(respBody.prefix(500)))")

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "OAuthError", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Token request failed (HTTP \(status)): \(String(respBody.prefix(200)))"
            ])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "OAuthError", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid token response"
            ])
        }

        // #6: Preserve existing refresh token if server omits it
        let newRefreshToken = (json["refresh_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            ?? loadRefreshToken() ?? ""
        let expiresIn = json["expires_in"] as? Double ?? 3600

        return TokenResponse(accessToken: accessToken, refreshToken: newRefreshToken,
                           expiresAt: Date.now.timeIntervalSince1970 + expiresIn)
    }

    // MARK: - Token Refresh Loop

    private func startTokenRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard !Task.isCancelled else { break }
                if let rt = loadRefreshToken(), !rt.isEmpty {
                    if let tokens = try? await refreshAccessToken(refreshToken: rt) {
                        saveTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt)
                    }
                }
            }
        }
    }

    // MARK: - Debug

    private func debugLog(_ message: String) {
        let log = "[\(Date())] \(message)\n"
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/oauth-debug.log"
        if let data = log.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
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

    // MARK: - Keychain (with ACL)

    private func saveTokens(accessToken: String, refreshToken: String, expiresAt: Double) {
        saveToKeychain(key: Self.accessTokenKey, value: accessToken)
        saveToKeychain(key: Self.refreshTokenKey, value: refreshToken)
        saveToKeychain(key: Self.expiresAtKey, value: String(expiresAt))
    }

    func loadAccessToken() -> String? { loadFromKeychain(key: Self.accessTokenKey) }
    private func loadRefreshToken() -> String? { loadFromKeychain(key: Self.refreshTokenKey) }
    private func loadExpiresAt() -> Double? { loadFromKeychain(key: Self.expiresAtKey).flatMap(Double.init) }

    // #1: Add kSecAttrAccessibleWhenUnlockedThisDeviceOnly to prevent cross-device token leakage
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
