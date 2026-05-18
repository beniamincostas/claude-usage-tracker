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

    private var logoutMessage: String? {
        guard let reason = oauthManager.logoutReason else { return nil }
        switch reason {
        case "sessionExpired":
            return "Session expired. Please log in again."
        case "noToken":
            return "No saved login found. Please authenticate."
        case "networkError":
            return "Cannot reach Anthropic. Check your connection and try again."
        default:
            return nil
        }
    }

    init() {
        Task { await UpdateChecker().checkForUpdate() }
    }

    var body: some Scene {
        MenuBarExtra {
            if isAuthenticated {
                UsagePopoverView(viewModel: viewModel, onLogout: logout)
            } else {
                AuthChoiceView(oauthManager: oauthManager, message: logoutMessage, onKeychainSelected: selectKeychain)
            }
        } label: {
            MenuBarLabel(viewModel: viewModel)
                // Reconnect OAuth on first label render after launch. `.onChange` below
                // only fires on transitions, so a user who started the app with
                // `authMethod = oauth` already persisted would otherwise be left
                // with a UsageAPIClient that has no OAuthManager handle and falls
                // back to the (empty) "Claude Code-credentials" keychain item —
                // producing the "Waiting for Claude Code" hint indefinitely.
                // The label view is materialised immediately at scene setup, before
                // the popover is opened, so this runs at launch.
                .task {
                    if authMethod == "oauth" && oauthManager.isAuthenticated {
                        viewModel.connectOAuth(oauthManager)
                    }
                }
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
