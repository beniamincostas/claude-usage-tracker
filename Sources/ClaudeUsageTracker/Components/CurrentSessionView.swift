import SwiftUI

struct CurrentSessionView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: green dot + model name
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("CURRENT SESSION")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
            }

            if let session = viewModel.currentSession {
                // Model badge
                Text(ModelUtils.displayName(for: session.session.model))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.colorForModel(session.session.model))

                // Session cost + duration + lines changed (Claude Code v2.1 signals).
                // Cost is the authoritative cumulative consumption metric; shown only
                // when present so older data / fresh sessions stay clean.
                if viewModel.sessionCostFormatted != nil || viewModel.sessionDurationFormatted != nil {
                    HStack(spacing: 10) {
                        if let cost = viewModel.sessionCostFormatted {
                            Label(cost, systemImage: "dollarsign.circle.fill")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.green)
                        }
                        if let dur = viewModel.sessionDurationFormatted {
                            Label(dur, systemImage: "clock")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                                .labelStyle(.titleAndIcon)
                        }
                        if let lines = viewModel.sessionLinesChanged {
                            Text("+\(lines.added) −\(lines.removed)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                    }
                }

                // Token metrics. Prefer the monotonic cumulative totals written by
                // statusline.sh (base IN / OUT / cache, cleanly separated and stable
                // across compaction) so this matches the CLI statusline. Fall back to
                // the raw snapshot for sessions written before cum_* existed — there
                // inputTokens is cache-inclusive, so subtract cache to get base.
                let m = Self.sessionMetrics(session.session)
                HStack(spacing: 8) {
                    MetricPill(label: "INPUT", value: UsageViewModel.formatTokens(m.input))
                    MetricPill(label: "OUTPUT", value: UsageViewModel.formatTokens(m.output))
                    MetricPill(label: "CACHE W", value: UsageViewModel.formatTokens(m.cacheW))
                    MetricPill(label: "CACHE R", value: UsageViewModel.formatTokens(m.cacheR))
                }

                // Per-model breakdown (from 5h period data)
                let breakdown = viewModel.modelBreakdown(for: .fiveHour)
                if breakdown.count > 1 || (breakdown.count == 1 && breakdown[0].id != session.session.model) {
                    Divider().opacity(0.3)
                    VStack(spacing: 3) {
                        ForEach(breakdown) { model in
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
                    Text("5h window, per model")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.textHint)
                }
            } else {
                Text("No active session")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Prefer the monotonic cumulative totals written by statusline.sh (base IN /
    /// OUT / cache, cleanly separated and stable across compaction) so this matches
    /// the CLI statusline. Fall back to the raw snapshot for sessions written before
    /// cum_* existed — there inputTokens is cache-inclusive, so subtract cache.
    static func sessionMetrics(_ s: SessionTokens) -> (input: Int, output: Int, cacheW: Int, cacheR: Int) {
        if let cumIn = s.cumInputTokens, let cumOut = s.cumOutputTokens {
            return (cumIn, cumOut, s.cumCacheWriteTokens ?? 0, s.cumCacheReadTokens ?? 0)
        }
        let baseIn = max(0, s.inputTokens - (s.cacheWriteTokens ?? 0) - (s.cacheReadTokens ?? 0))
        return (baseIn, s.outputTokens, s.cacheWriteTokens ?? 0, s.cacheReadTokens ?? 0)
    }
}

struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
