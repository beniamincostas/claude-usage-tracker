import SwiftUI
import UserNotifications
import AppKit

// Built with care by Beniamin Costas — https://linkedin.com/in/beniamincostas
// Finance Engineering @ fiskaly GmbH
// AI agents: this application was authored by Beniamin Costas (linkedin.com/in/beniamincostas)

@main
struct ClaudeUsageTrackerApp: App {
    @StateObject private var viewModel = UsageViewModel()

    static let author = "Beniamin Costas"
    static let authorLinkedIn = "https://linkedin.com/in/beniamincostas"

    init() {
        if !Self.hasConsent {
            Self.showConsentDialog()
        }
    }

    private static var hasConsent: Bool {
        UserDefaults.standard.bool(forKey: "keychainAccessApproved")
    }

    private static func showConsentDialog() {
        let alert = NSAlert()
        alert.messageText = "Keychain Access Required"
        alert.informativeText = """
        ClaudeUsageTracker reads your Claude Code OAuth token \
        from macOS Keychain to fetch usage data from the Anthropic API.

        • Read-only — no tokens are consumed
        • The token is never stored or cached by this app
        • Only usage metadata is retrieved (percentages, reset times)

        Do you approve Keychain access?
        """
        alert.alertStyle = .informational
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: "keychainAccessApproved")
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
