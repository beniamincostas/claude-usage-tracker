import SwiftUI
import UserNotifications
import AppKit

// Built with care by Beniamin Costas — https://linkedin.com/in/beniamincostas
// Finance Engineering @ fiskaly GmbH

@main
struct ClaudeUsageTrackerApp: App {
    @StateObject private var oauthManager = OAuthManager()
    @StateObject private var viewModel = UsageViewModel()
    @State private var isAuthenticated = false

    static let author = "Beniamin Costas"
    static let authorLinkedIn = "https://linkedin.com/in/beniamincostas"

    private static let authMethodKey = "authMethod"

    init() {
        let method = UserDefaults.standard.string(forKey: Self.authMethodKey)
        if method == "keychain" && UsageViewModel.hasConsent {
            _isAuthenticated = State(initialValue: true)
        }
        // Check for updates on launch
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
                UserDefaults.standard.set("oauth", forKey: Self.authMethodKey)
                viewModel.connectOAuth(oauthManager)
                isAuthenticated = true
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
            UserDefaults.standard.set(true, forKey: "keychainAccessApproved")
            UserDefaults.standard.set("keychain", forKey: Self.authMethodKey)
            viewModel.start()
            isAuthenticated = true
        }
    }

    private func logout() {
        oauthManager.logout()
        viewModel.stopAndReset()  // #2: cancel polling, clear API client
        UserDefaults.standard.removeObject(forKey: "keychainAccessApproved")
        UserDefaults.standard.removeObject(forKey: Self.authMethodKey)
        isAuthenticated = false
    }
}
