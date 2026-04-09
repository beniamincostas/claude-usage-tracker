import Foundation
import AppKit

/// Checks GitHub releases for a newer version on launch.
actor UpdateChecker {
    private static let owner = "beniamincostas"
    private static let repo = "claude-usage-tracker"
    private static let currentVersion = "2.0.0"

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
    }

    func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return
        }

        let latestTag = release.tag_name.replacingOccurrences(of: "v", with: "")
        guard isNewer(latestTag, than: Self.currentVersion) else { return }

        await MainActor.run {
            showUpdateAlert(version: release.tag_name, notes: release.body, url: release.html_url)
        }
    }

    /// Simple version comparison — handles semver and beta suffixes
    private func isNewer(_ remote: String, than local: String) -> Bool {
        // Strip "-beta" for comparison
        let r = remote.replacingOccurrences(of: "-beta", with: "")
        let l = local.replacingOccurrences(of: "-beta", with: "")

        let rParts = r.split(separator: ".").compactMap { Int($0) }
        let lParts = l.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(rParts.count, lParts.count) {
            let rv = i < rParts.count ? rParts[i] : 0
            let lv = i < lParts.count ? lParts[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }

        // Same base version: non-beta is newer than beta
        if !remote.contains("-beta") && local.contains("-beta") { return true }
        return false
    }

    @MainActor
    private func showUpdateAlert(version: String, notes: String?, url: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available: \(version)"

        var info = "A new version of ClaudeUsageTracker is available.\n"
        if let notes, !notes.isEmpty {
            // Trim to first 500 chars to keep the dialog reasonable
            let trimmed = notes.count > 500 ? String(notes.prefix(500)) + "..." : notes
            info += "\nWhat's new:\n\(trimmed)"
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            // #5: Validate URL scheme and domain before opening
            if let downloadURL = URL(string: url),
               downloadURL.scheme == "https",
               downloadURL.host?.hasSuffix("github.com") == true {
                NSWorkspace.shared.open(downloadURL)
            }
        }
    }
}
