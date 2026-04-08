import SwiftUI

struct CurrentSessionView: View {
    let viewModel: UsageViewModel

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

                // Token metrics — session-level inputTokens includes cache, so subtract for base
                let baseIn = max(0, session.session.inputTokens
                    - (session.session.cacheWriteTokens ?? 0)
                    - (session.session.cacheReadTokens ?? 0))
                HStack(spacing: 8) {
                    MetricPill(label: "INPUT", value: UsageViewModel.formatTokens(baseIn))
                    MetricPill(label: "OUTPUT", value: UsageViewModel.formatTokens(session.session.outputTokens))
                    MetricPill(label: "CACHE W", value: UsageViewModel.formatTokens(session.session.cacheWriteTokens ?? 0))
                    MetricPill(label: "CACHE R", value: UsageViewModel.formatTokens(session.session.cacheReadTokens ?? 0))
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
