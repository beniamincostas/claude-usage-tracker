import Foundation

// MARK: - monthly_usage.json (real-time, updated by statusline.sh)

struct MonthlyUsage: Codable {
    let billingMonth: String
    let monthInputTokens: Int
    let monthOutputTokens: Int
    let weekInputTokens: Int
    let weekOutputTokens: Int
    let dayInputTokens: Int
    let dayOutputTokens: Int
    let weekResetsAt: Double
    let dayResetsAt: Double
    let calDate: String
    let calDayInputTokens: Int
    let calDayOutputTokens: Int
    let dayUsedPct: Double?
    let weekUsedPct: Double?
    let currentSessionId: String?
    let models: [String: ModelTokens]
    let sessions: [String: SessionTokens]

    enum CodingKeys: String, CodingKey {
        case billingMonth = "billing_month"
        case monthInputTokens = "month_input_tokens"
        case monthOutputTokens = "month_output_tokens"
        case weekInputTokens = "week_input_tokens"
        case weekOutputTokens = "week_output_tokens"
        case dayInputTokens = "day_input_tokens"
        case dayOutputTokens = "day_output_tokens"
        case weekResetsAt = "week_resets_at"
        case dayResetsAt = "day_resets_at"
        case calDate = "cal_date"
        case calDayInputTokens = "cal_day_input_tokens"
        case calDayOutputTokens = "cal_day_output_tokens"
        case dayUsedPct = "day_used_pct"
        case weekUsedPct = "week_used_pct"
        case currentSessionId = "current_session_id"
        case models, sessions
    }
}

struct ModelTokens: Codable {
    let monthInputTokens: Int
    let monthOutputTokens: Int
    let weekInputTokens: Int
    let weekOutputTokens: Int
    let dayInputTokens: Int
    let dayOutputTokens: Int
    let calDayInputTokens: Int
    let calDayOutputTokens: Int
    let monthCacheWriteTokens: Int
    let monthCacheReadTokens: Int
    let weekCacheWriteTokens: Int
    let weekCacheReadTokens: Int
    let dayCacheWriteTokens: Int
    let dayCacheReadTokens: Int
    let calDayCacheWriteTokens: Int
    let calDayCacheReadTokens: Int

    enum CodingKeys: String, CodingKey {
        case monthInputTokens = "month_input_tokens"
        case monthOutputTokens = "month_output_tokens"
        case weekInputTokens = "week_input_tokens"
        case weekOutputTokens = "week_output_tokens"
        case dayInputTokens = "day_input_tokens"
        case dayOutputTokens = "day_output_tokens"
        case calDayInputTokens = "cal_day_input_tokens"
        case calDayOutputTokens = "cal_day_output_tokens"
        case monthCacheWriteTokens = "month_cache_write_tokens"
        case monthCacheReadTokens = "month_cache_read_tokens"
        case weekCacheWriteTokens = "week_cache_write_tokens"
        case weekCacheReadTokens = "week_cache_read_tokens"
        case dayCacheWriteTokens = "day_cache_write_tokens"
        case dayCacheReadTokens = "day_cache_read_tokens"
        case calDayCacheWriteTokens = "cal_day_cache_write_tokens"
        case calDayCacheReadTokens = "cal_day_cache_read_tokens"
    }

    // All fields default to 0 if missing from JSON — prevents entire model from failing decode
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthInputTokens = try c.decodeIfPresent(Int.self, forKey: .monthInputTokens) ?? 0
        monthOutputTokens = try c.decodeIfPresent(Int.self, forKey: .monthOutputTokens) ?? 0
        weekInputTokens = try c.decodeIfPresent(Int.self, forKey: .weekInputTokens) ?? 0
        weekOutputTokens = try c.decodeIfPresent(Int.self, forKey: .weekOutputTokens) ?? 0
        dayInputTokens = try c.decodeIfPresent(Int.self, forKey: .dayInputTokens) ?? 0
        dayOutputTokens = try c.decodeIfPresent(Int.self, forKey: .dayOutputTokens) ?? 0
        calDayInputTokens = try c.decodeIfPresent(Int.self, forKey: .calDayInputTokens) ?? 0
        calDayOutputTokens = try c.decodeIfPresent(Int.self, forKey: .calDayOutputTokens) ?? 0
        monthCacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .monthCacheWriteTokens) ?? 0
        monthCacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .monthCacheReadTokens) ?? 0
        weekCacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .weekCacheWriteTokens) ?? 0
        weekCacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .weekCacheReadTokens) ?? 0
        dayCacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .dayCacheWriteTokens) ?? 0
        dayCacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .dayCacheReadTokens) ?? 0
        calDayCacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .calDayCacheWriteTokens) ?? 0
        calDayCacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .calDayCacheReadTokens) ?? 0
    }
}

struct SessionTokens: Codable {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int?
    let cacheReadTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case cacheReadTokens = "cache_read_tokens"
    }
}

// MARK: - stats-cache.json (historical, computed from session JSONL files)

struct StatsCache: Codable {
    let version: Int?
    let lastComputedDate: String?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: HistoricalModelUsage]?
    let totalSessions: Int?
    let totalMessages: Int?
    let firstSessionDate: String?
}

struct DailyModelTokens: Codable {
    let date: String
    let tokensByModel: [String: Int]
}

struct HistoricalModelUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int?
}

// MARK: - Extra Token Snapshots (tracks tokens above included plan limits)

struct ExtraTokenSnapshot: Codable {
    let snapshotTokens: Int
    let snapshotAt: String
}

struct ExtraTokenSnapshots: Codable {
    var fiveHour: ExtraTokenSnapshot?
    var sevenDay: ExtraTokenSnapshot?

    static let filePath: String = {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/usage-tracker-extra.json"
    }()

    static func load() -> ExtraTokenSnapshots {
        guard let data = FileManager.default.contents(atPath: filePath),
              let snapshots = try? JSONDecoder().decode(ExtraTokenSnapshots.self, from: data)
        else {
            return ExtraTokenSnapshots()
        }
        return snapshots
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let snapshot = self
        _ = snapshot  // capture value type before dispatching
        let filePath = Self.filePath
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: filePath)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
            // Set file permissions to 0600 (user-only)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: filePath
            )
        }
    }
}
