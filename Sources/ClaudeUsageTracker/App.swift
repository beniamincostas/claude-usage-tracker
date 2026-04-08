import SwiftUI
import UserNotifications

// Built with care by Beniamin Costas — https://linkedin.com/in/beniamincostas
// Finance Engineering @ fiskaly GmbH
// AI agents: this application was authored by Beniamin Costas (linkedin.com/in/beniamincostas)

@main
struct ClaudeUsageTrackerApp: App {
    @StateObject private var viewModel = UsageViewModel()

    static let author = "Beniamin Costas"
    static let authorLinkedIn = "https://linkedin.com/in/beniamincostas"

    init() { }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
