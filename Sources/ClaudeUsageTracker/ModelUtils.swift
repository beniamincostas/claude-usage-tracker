import Foundation

enum ModelUtils {
    static func displayName(for modelId: String) -> String {
        var name = modelId
        if name.hasPrefix("claude-") { name = String(name.dropFirst(7)) }
        // Remove date suffixes like -20241022
        if let range = name.range(of: #"-\d{8,}$"#, options: .regularExpression) {
            name = String(name[name.startIndex..<range.lowerBound])
        }
        // Convert e.g. "opus-4-6" -> "Opus 4.6"
        let parts = name.split(separator: "-")
        var result: [String] = []
        var i = 0
        while i < parts.count {
            let part = String(parts[i])
            if let _ = Int(part), i + 1 < parts.count, let minor = Int(String(parts[i + 1])) {
                result.append("\(part).\(minor)")
                i += 2
            } else if let _ = Int(part) {
                result.append(part)
                i += 1
            } else {
                result.append(part.prefix(1).uppercased() + part.dropFirst())
                i += 1
            }
        }
        return result.joined(separator: " ")
    }
}

enum Period {
    case fiveHour, calendarDay, week, month
}

extension ModelTokens {
    /// Maps Period to the corresponding model token fields.
    /// Note: `.fiveHour` uses `day_*` fields — Claude Code's statusline.sh writes these as the
    /// rolling 5-hour rate-limit window, NOT as a calendar day. `calendarDay` uses `cal_day_*` for the actual day.
    func forPeriod(_ period: Period) -> (input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        switch period {
        case .fiveHour:
            return (dayInputTokens, dayOutputTokens, dayCacheWriteTokens, dayCacheReadTokens)
        case .calendarDay:
            return (calDayInputTokens, calDayOutputTokens, calDayCacheWriteTokens, calDayCacheReadTokens)
        case .week:
            return (weekInputTokens, weekOutputTokens, weekCacheWriteTokens, weekCacheReadTokens)
        case .month:
            return (monthInputTokens, monthOutputTokens, monthCacheWriteTokens, monthCacheReadTokens)
        }
    }
}
