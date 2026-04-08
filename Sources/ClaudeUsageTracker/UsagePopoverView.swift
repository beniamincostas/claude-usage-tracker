import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var allTimeExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.usage != nil || viewModel.apiUsage != nil || viewModel.statsCache != nil {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        header.padding(.bottom, 2)

                        // 5-Hour Window (shortest timeframe first)
                        if viewModel.usage != nil || viewModel.apiUsage != nil {
                            let t5h = viewModel.tokens(for: .fiveHour)
                            PeriodUsageView(
                                title: "5-HOUR WINDOW",
                                icon: "clock",
                                percentage: viewModel.fiveHourPercentage,
                                countdown: viewModel.fiveHourCountdown,
                                inputTokens: t5h.input,
                                outputTokens: t5h.output,
                                cacheWriteTokens: t5h.cacheWrite,
                                cacheReadTokens: t5h.cacheRead,
                                modelBreakdown: viewModel.modelBreakdown(for: .fiveHour),
                                extraTokens: viewModel.fiveHourExtraTokens,
                                timeToLimit: viewModel.fiveHourTimeToLimit,
                                isStale: !viewModel.isAPIDataFresh
                            )
                        }

                        // 7-Day Usage
                        if viewModel.usage != nil || viewModel.apiUsage != nil {
                            let t7d = viewModel.tokens(for: .week)
                            PeriodUsageView(
                                title: "7-DAY USAGE",
                                icon: "calendar.badge.clock",
                                percentage: viewModel.weekPercentage,
                                countdown: viewModel.weekCountdown,
                                inputTokens: t7d.input,
                                outputTokens: t7d.output,
                                cacheWriteTokens: t7d.cacheWrite,
                                cacheReadTokens: t7d.cacheRead,
                                modelBreakdown: viewModel.modelBreakdown(for: .week),
                                extraTokens: viewModel.weekExtraTokens,
                                timeToLimit: viewModel.weekTimeToLimit,
                                subBuckets: viewModel.weekSubBuckets,
                                isStale: !viewModel.isAPIDataFresh
                            )
                        }

                        // Today + Monthly side by side
                        if viewModel.usage != nil {
                            todayAndMonthly
                        }

                        // Extra Usage (API-sourced dollar credits)
                        if viewModel.extraUsageEnabled && viewModel.extraUsageCredits > 0 {
                            extraUsageCard
                        }

                        // All-Time Historical (from stats-cache.json — Opus + Sonnet + all models)
                        if !viewModel.historicalModels.isEmpty {
                            allTimeSection
                        }

                        footer
                    }
                    .padding(14)
                }
            } else {
                emptyState
            }
        }
        .frame(width: 420, height: 600)
        .background(Theme.bgPrimary)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            // Top line: fiskaly logo (left) + Claude Usage (right)
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 4) {
                    Text("fiskaly")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                }

                Spacer()

                Text("Claude Usage")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }

            // Second line: billing month + status
            HStack {
                if let month = viewModel.usage?.billingMonth {
                    Text(month)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                HStack(spacing: 3) {
                    Circle()
                        .fill(viewModel.isAPIDataFresh ? Theme.accent : Color.orange)
                        .frame(width: 4, height: 4)
                    Text(viewModel.timeSinceUpdate)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(viewModel.isAPIDataFresh ? Theme.textTertiary : Color.orange)
                }
            }
        }
    }

    // MARK: - Today + Monthly (full-width card with per-model breakdown)

    private var todayAndMonthly: some View {
        let tMonth = viewModel.tokens(for: .month)
        let tToday = viewModel.tokens(for: .calendarDay)
        // Total = all 4 token types (input + output + cache write + cache read)
        let monthTotal = tMonth.input + tMonth.output + tMonth.cacheWrite + tMonth.cacheRead
        let todayTotal = tToday.input + tToday.output + tToday.cacheWrite + tToday.cacheRead

        return VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("BILLING MONTH")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(0.5)
                }
                Spacer()
                Text(viewModel.monthCountdown)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            // Month total + Today total side by side
            HStack(spacing: 16) {
                // Month total
                VStack(alignment: .leading, spacing: 2) {
                    Text("MONTH TOTAL")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(UsageViewModel.formatTokens(monthTotal))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }

                // Today total
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(UsageViewModel.formatTokens(todayTotal))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer()
            }

            // Metrics row (month-level — all 4 token types shown separately)
            HStack(spacing: 8) {
                MetricPill(label: "INPUT", value: UsageViewModel.formatTokens(tMonth.input))
                MetricPill(label: "OUTPUT", value: UsageViewModel.formatTokens(tMonth.output))
                MetricPill(label: "CACHE W", value: UsageViewModel.formatTokens(tMonth.cacheWrite))
                MetricPill(label: "CACHE R", value: UsageViewModel.formatTokens(tMonth.cacheRead))
            }

            // Per-model breakdown (month-level — shows ALL models used this billing period)
            let monthBreakdown = viewModel.modelBreakdown(for: .month)
            if monthBreakdown.count > 0 {
                let grandTotal = monthBreakdown.reduce(0) { $0 + $1.total }
                VStack(spacing: 4) {
                    ForEach(monthBreakdown) { model in
                        let pct = grandTotal > 0 ? Double(model.total) / Double(grandTotal) * 100 : 0
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.colorForModel(model.id))
                                .frame(width: 5, height: 5)
                            Text(model.displayName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Text(String(format: "%.0f%%", pct))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.colorForModel(model.id).opacity(0.7))
                            Spacer()
                            Text(UsageViewModel.formatTokens(model.total))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - All-Time Historical (Opus + Sonnet from stats-cache.json)

    private var allTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Clickable header — toggles expansion
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text("ALL-TIME USAGE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)

                if !allTimeExpanded {
                    // Compact summary when collapsed
                    Text("· \(viewModel.totalSessionsAllTime) sessions")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Image(systemName: allTimeExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { allTimeExpanded.toggle() }
            }

            if allTimeExpanded {
                if let first = viewModel.statsCache?.firstSessionDate {
                    let dateStr = String(first.prefix(10))
                    Text("Since \(dateStr)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(spacing: 6) {
                    ForEach(viewModel.historicalModels) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.colorForModel(model.id))
                                    .frame(width: 8, height: 8)
                                Text(model.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(UsageViewModel.formatTokens(model.inputTokens + model.outputTokens + model.cacheReadTokens + model.cacheCreationTokens))
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                            }

                            HStack(spacing: 12) {
                                miniStat(label: "Input", value: UsageViewModel.formatTokens(model.inputTokens))
                                miniStat(label: "Output", value: UsageViewModel.formatTokens(model.outputTokens))
                                miniStat(label: "Cache Read", value: UsageViewModel.formatTokens(model.cacheReadTokens))
                                miniStat(label: "Cache Write", value: UsageViewModel.formatTokens(model.cacheCreationTokens))
                            }
                        }
                        .padding(8)
                        .background(Theme.bgCardHover, in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                HStack(spacing: 16) {
                    miniStat(label: "Sessions", value: "\(viewModel.totalSessionsAllTime)")
                    miniStat(label: "Messages", value: "\(viewModel.totalMessagesAllTime)")
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 10))
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.3)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Extra Usage Card (API-sourced dollar credits)

    private var extraUsageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("EXTRA USAGE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                Spacer()
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SPENT")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(viewModel.extraUsageFormatted)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }

                if viewModel.extraUsageMonthlyLimit > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LIMIT")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(String(format: "$%.0f", viewModel.extraUsageMonthlyLimit))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()
            }

            if viewModel.extraUsageUtilization > 0 {
                HStack(spacing: 10) {
                    UsageProgressBar(
                        percentage: viewModel.extraUsageUtilization,
                        height: 8,
                        color: .orange
                    )
                    Text("\(Int(viewModel.extraUsageUtilization))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.bgCardHover, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text("Waiting for Claude Code...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Start a session to see usage data")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
