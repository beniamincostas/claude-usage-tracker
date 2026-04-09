import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var pulseVisible = true

    var body: some View {
        HStack(spacing: 3) {
            // App icon — distinct shape per alert level
            Image(systemName: menuBarIcon)
                .font(.system(size: 11, weight: .medium))

            // 5h bar (normal state only — hidden at alert levels to save space)
            if viewModel.fiveHourAlertLevel == .normal, viewModel.fiveHourPercentage != nil {
                CompactBar(
                    percentage: viewModel.menuBarBarPercentage,
                    width: 32,
                    height: 4,
                    pulsing: false
                )
            }

            // 5h percentage text with alert markers baked into the string
            Text(menuBarDisplayText)
                .monospacedDigit()
                .font(.system(size: 11, weight: viewModel.fiveHourAlertLevel >= .warning90 ? .bold : .medium))

            // 7d warning: show "7d" marker when that bucket is also critical
            if viewModel.sevenDayAlertLevel >= .warning90 {
                Text("7d\(viewModel.sevenDayAlertLevel == .maxed100 ? "!" : "")")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
        }
    }

    /// Build the display string with alert markers since macOS strips colors
    private var menuBarDisplayText: String {
        let base = viewModel.menuBarText
        switch viewModel.fiveHourAlertLevel {
        case .maxed100: return "\(base) LIMIT"
        case .critical95: return "\(base)!!"
        case .warning90: return "\(base)!"
        case .normal: return base
        }
    }

    private var menuBarIcon: String {
        switch viewModel.fiveHourAlertLevel {
        case .maxed100: return "exclamationmark.octagon.fill"
        case .critical95: return "exclamationmark.triangle.fill"
        case .warning90: return "exclamationmark.triangle"
        case .normal: return "gauge.with.needle.fill"
        }
    }

}
