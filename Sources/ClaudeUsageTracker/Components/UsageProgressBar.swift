import SwiftUI

struct UsageProgressBar: View {
    let percentage: Double
    let height: CGFloat
    let color: Color?

    init(percentage: Double, height: CGFloat = 10, color: Color? = nil) {
        self.percentage = percentage
        self.height = height
        self.color = color
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Theme.barTrack)

                // Fill
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [fillColor.opacity(0.8), fillColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geo.size.width * min(max(percentage / 100, 0), 1.0), 0))
                    .animation(.easeInOut(duration: 0.4), value: percentage)
            }
        }
        .frame(height: height)
    }

    private var fillColor: Color {
        color ?? Theme.barColor(for: percentage)
    }
}

// Compact bar for the menu bar area (thinner, optional pulse animation)
struct CompactBar: View {
    let percentage: Double
    let width: CGFloat
    let height: CGFloat
    let pulsing: Bool
    @State private var pulseOpacity: Double = 1.0

    init(percentage: Double, width: CGFloat = 40, height: CGFloat = 4, pulsing: Bool = false) {
        self.percentage = percentage
        self.width = width
        self.height = height
        self.pulsing = pulsing
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Color.gray.opacity(0.3))
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Theme.barColor(for: percentage))
                .frame(width: max(width * min(max(percentage / 100, 0), 1.0), 0), height: height)
                .opacity(pulsing ? pulseOpacity : 1.0)
                .animation(pulsing ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: pulseOpacity)
                .onAppear { if pulsing { pulseOpacity = 0.5 } }
                .onChange(of: pulsing) { newValue in
                    pulseOpacity = newValue ? 0.5 : 1.0
                }
        }
    }
}
