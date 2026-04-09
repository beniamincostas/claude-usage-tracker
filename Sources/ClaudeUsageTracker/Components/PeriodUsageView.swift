import SwiftUI

struct PeriodUsageView: View {
    let title: String
    let icon: String
    let percentage: UsageViewModel.RateLimitPercentage?  // nil = no data, don't show bar
    let countdown: String
    let inputTokens: Int       // base new input (non-cache)
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let modelBreakdown: [UsageViewModel.ModelSummary]
    var extraTokens: Int? = nil
    var timeToLimit: String? = nil
    var subBuckets: [UsageViewModel.SubBucket] = []
    var isStale: Bool = false

    private var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    private var alertLevel: UsageViewModel.AlertLevel {
        guard let pct = percentage else { return .normal }
        return .from(percentage: pct.value)
    }

    private var alertBorderColor: Color {
        switch alertLevel {
        case .maxed100: return Theme.barDanger
        case .critical95: return Theme.barDanger.opacity(0.7)
        case .warning90: return Theme.barWarning.opacity(0.6)
        case .normal: return .clear
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Alert banner at threshold
            if alertLevel >= .warning90 {
                HStack(spacing: 6) {
                    Image(systemName: alertLevel == .maxed100 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(alertLevel == .maxed100 ? "Rate limit reached" : alertLevel == .critical95 ? "Almost at limit" : "Approaching limit")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(alertLevel >= .critical95 ? Theme.barDanger : Theme.barWarning)
                .padding(.bottom, 2)
            }

            // Header with title and countdown
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(alertLevel >= .warning90 ? alertBorderColor : Theme.accent)
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(0.5)
                }

                Spacer()

                Text(countdown)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(alertLevel >= .warning90 ? alertBorderColor : Theme.textTertiary)
            }

            // Main progress bar + percentage (real data only)
            if let pct = percentage {
                HStack(spacing: 10) {
                    UsageProgressBar(
                        percentage: pct.value,
                        height: 12,
                        color: isStale ? Color.secondary.opacity(0.5) : nil
                    )
                    HStack(spacing: 3) {
                        Text("\(Int(pct.value))%")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(isStale ? Theme.textTertiary : Theme.barColor(for: pct.value))
                        if isStale {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 48, alignment: .trailing)
                }
            }

            // Time-to-limit estimate
            if let ttl = timeToLimit {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(ttl)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            // Extra tokens above included plan limit
            if let extra = extraTokens, extra > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("Above limit:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                    Text(UsageViewModel.formatTokens(extra))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            // Metrics row — only shown when there's token data
            if totalTokens > 0 {
                HStack(spacing: 8) {
                    MetricPill(label: "INPUT", value: UsageViewModel.formatTokens(inputTokens))
                    MetricPill(label: "OUTPUT", value: UsageViewModel.formatTokens(outputTokens))
                    MetricPill(label: "CACHE W", value: UsageViewModel.formatTokens(cacheWriteTokens))
                    MetricPill(label: "CACHE R", value: UsageViewModel.formatTokens(cacheReadTokens))
                }
            }

            // Model breakdown
            if totalTokens > 0 && modelBreakdown.count > 1 {
                VStack(spacing: 4) {
                    ForEach(modelBreakdown) { model in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.colorForModel(model.id))
                                .frame(width: 5, height: 5)
                            Text(model.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(UsageViewModel.formatTokens(model.total))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Sub-buckets (API-sourced per-model rate limits, e.g. Opus/Sonnet within 7d)
            if !subBuckets.isEmpty {
                Divider().opacity(0.3)
                VStack(spacing: 6) {
                    ForEach(subBuckets) { bucket in
                        HStack(spacing: 8) {
                            Text(bucket.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 50, alignment: .leading)
                            UsageProgressBar(
                                percentage: bucket.percentage,
                                height: 6,
                                color: Theme.colorForModel(bucket.id)
                            )
                            Text("\(Int(bucket.percentage))%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.barColor(for: bucket.percentage))
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(alertLevel >= .warning90
                    ? alertBorderColor.opacity(0.06)
                    : Theme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(alertBorderColor, lineWidth: alertLevel >= .critical95 ? 1.5 : 1)
                .opacity(alertLevel >= .warning90 ? 1 : 0)
        )
    }
}
