import SwiftUI
import UserNotifications
import AppKit

// Built with care by Beniamin Costas — https://linkedin.com/in/beniamincostas
// Finance Engineering @ fiskaly GmbH

@main
struct ClaudeUsageTrackerApp: App {
    @StateObject private var oauthManager = OAuthManager()
    @StateObject private var viewModel = UsageViewModel()
    @AppStorage("authMethod") private var authMethod: String = ""
    @AppStorage("keychainAccessApproved") private var keychainApproved = false

    static let author = "Beniamin Costas"
    static let authorLinkedIn = "https://linkedin.com/in/beniamincostas"

    private var isAuthenticated: Bool {
        (authMethod == "oauth" && oauthManager.isAuthenticated) ||
        (authMethod == "keychain" && keychainApproved)
    }

    init() {
        Task { await UpdateChecker().checkForUpdate() }
    }

    var body: some Scene {
        MenuBarExtra {
            if isAuthenticated {
                UsagePopoverView(viewModel: viewModel, onLogout: logout)
            } else {
                AuthChoiceView(oauthManager: oauthManager, onKeychainSelected: selectKeychain)
            }
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: oauthManager.isAuthenticated) { authenticated in
            if authenticated {
                authMethod = "oauth"
                viewModel.connectOAuth(oauthManager)
            }
        }
        .onChange(of: keychainApproved) { approved in
            if approved && authMethod == "keychain" {
                viewModel.start()
            }
        }
    }

    private func selectKeychain() {
        let alert = NSAlert()
        alert.messageText = "Keychain Access"
        alert.informativeText = """
        The app will read Claude Code's OAuth token from \
        macOS Keychain to fetch usage data.

        • Read-only — no tokens are consumed
        • Only usage metadata is retrieved
        • Requires Claude Code CLI installed and logged in

        Approve?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            authMethod = "keychain"
            keychainApproved = true
        }
    }

    private func logout() {
        oauthManager.logout()
        viewModel.stopAndReset()
        keychainApproved = false
        authMethod = ""
    }
}
