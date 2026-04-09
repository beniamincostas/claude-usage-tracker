import SwiftUI

struct AuthChoiceView: View {
    @ObservedObject var oauthManager: OAuthManager
    var onKeychainSelected: () -> Void
    @State private var codeInput = ""

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text("fiskaly")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
                Text("Claude Usage Tracker")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }

            Divider()

            if oauthManager.isLoggingIn {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste the code from your browser:")
                        .font(.system(size: 12, weight: .medium))
                    TextField("code#state", text: $codeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    HStack {
                        Button("Submit") {
                            Task { await oauthManager.completeLogin(codeWithState: codeInput) }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(codeInput.isEmpty)
                        Button("Cancel") { oauthManager.isLoggingIn = false; codeInput = "" }
                            .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Text("Choose how to connect:")
                        .font(.system(size: 12, weight: .medium))
                    Button(action: { oauthManager.startLogin() }) {
                        VStack(spacing: 4) {
                            Text("Login with Anthropic").font(.system(size: 13, weight: .semibold))
                            Text("Opens browser — no Claude Code needed").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)

                    Text("or").font(.system(size: 11)).foregroundStyle(.tertiary)

                    Button(action: onKeychainSelected) {
                        VStack(spacing: 4) {
                            Text("Use Claude Code Keychain").font(.system(size: 13, weight: .semibold))
                            Text("Reads token from Claude Code — requires CLI installed").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let error = oauthManager.loginError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
            }
        }
        .padding(16)
        .frame(width: 320, height: 320)
        .background(Theme.bgPrimary)
    }
}
