import Foundation

// MARK: - API Response Models

struct UsageAPIResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let sevenDayOauthApps: UsageBucket?
    let sevenDayCowork: UsageBucket?
    let iguanaNecktie: UsageBucket?
    let extraUsage: ExtraUsageAPI?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }
}

struct UsageBucket: Codable {
    let utilization: Double   // 0–100
    let resetsAt: String?     // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsageAPI: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

// MARK: - API Client

actor UsageAPIClient {
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum FetchError {
        case noToken
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case timeout
        case httpError(Int)
        case networkError
        case parseError
    }

    enum FetchResult {
        case success(UsageAPIResponse)
        case failure(FetchError)
    }

    func fetchUsage() async -> FetchResult {
        guard let token = await getToken() else {
            return .failure(.noToken)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.networkError)
            }
            if http.statusCode == 401 {
                return .failure(.unauthorized)
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "retry-after")
                    .flatMap { Double($0) }
                return .failure(.rateLimited(retryAfter: retryAfter))
            }
            guard http.statusCode == 200 else {
                return .failure(.httpError(http.statusCode))
            }
            let decoded = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
            return .success(decoded)
        } catch is DecodingError {
            return .failure(.parseError)
        } catch let urlError as URLError where urlError.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.networkError)
        }
    }

    /// Read token from Keychain via the `security` CLI each time.
    /// Uses the system binary which is trusted by Keychain ACLs — no user prompt.
    /// 5-second timeout prevents polling loop from freezing if security CLI hangs.
    private func getToken() async -> String? {
        let raw: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                var resumed = false
                let lock = NSLock()

                func safeResume(_ value: String?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: value)
                }

                // Watchdog: kill process after 5 seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { process.terminate() }
                    safeResume(nil)
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        safeResume(nil)
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let result = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    safeResume(result?.isEmpty == true ? nil : result)
                } catch {
                    safeResume(nil)
                }
            }
        }

        guard let raw, !raw.isEmpty else { return nil }

        // Parse only accessToken and expiresAt — avoid holding refreshToken in memory
        guard let jsonData = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        if let oauth = json["claudeAiOauth"] as? [String: Any] {
            guard let accessToken = oauth["accessToken"] as? String else { return nil }
            if let expiresAt = oauth["expiresAt"] as? Double {
                let nowMs = Date.now.timeIntervalSince1970 * 1000
                if nowMs > expiresAt { return nil }
            }
            return accessToken
        }
        if let accessToken = json["access_token"] as? String {
            return accessToken
        }
        return nil
    }
}
