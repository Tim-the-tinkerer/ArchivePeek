import AppKit
import Foundation

package enum UpdateChecker {
    enum Outcome: Sendable {
        case upToDate(current: String)
        case updateAvailable(current: String, latest: String, releaseURL: URL)
        case noReleases(current: String)
        case failed(message: String)
    }

    /// Compare the running app version with the latest GitHub release tag.
    static func checkForUpdates() async -> Outcome {
        let current = AppInfo.version
        var request = URLRequest(url: AppInfo.githubLatestReleaseAPIURL)
        request.setValue("ArchivePeek/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    return .noReleases(current: current)
                }
                guard (200...299).contains(http.statusCode) else {
                    return .failed(message: "GitHub returned status \(http.statusCode).")
                }
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String
            else {
                return .failed(message: "Could not read the latest release information.")
            }

            let latest = normalizedVersion(tag)
            let releasePage: URL = {
                if let html = json["html_url"] as? String, let url = URL(string: html) {
                    return url
                }
                return AppInfo.githubReleasesURL
            }()

            if isRemoteVersion(latest, newerThan: current) {
                return .updateAvailable(current: current, latest: latest, releaseURL: releasePage)
            }
            return .upToDate(current: current)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Present a modal result and open the repository/releases when appropriate.
    @MainActor
    static func presentCheckResult(_ outcome: Outcome) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch outcome {
        case .upToDate(let current):
            alert.messageText = "You’re up to date"
            alert.informativeText = "ArchivePeek \(current) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open GitHub")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(AppInfo.githubRepositoryURL)
            }

        case .updateAvailable(let current, let latest, let releaseURL):
            alert.messageText = "Update available"
            alert.informativeText = "ArchivePeek \(latest) is available. You have \(current).\n\nDownload the latest release from GitHub."
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(releaseURL)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(AppInfo.githubRepositoryURL)
            default:
                break
            }

        case .noReleases(let current):
            alert.messageText = "No releases found"
            alert.informativeText = "You’re running ArchivePeek \(current). No published releases were found on GitHub yet — open the project page for the latest build."
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(AppInfo.githubRepositoryURL)
            }

        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = "\(message)\n\nYou can still open the project page on GitHub."
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(AppInfo.githubRepositoryURL)
            }
        }
    }

    @MainActor
    package static func checkAndPresent() {
        Task {
            let outcome = await checkForUpdates()
            presentCheckResult(outcome)
        }
    }

    // MARK: - Version compare

    /// Strip a leading `v`/`V` and any build metadata after `+`.
    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value = String(value.dropFirst())
        }
        if let plus = value.firstIndex(of: "+") {
            value = String(value[..<plus])
        }
        return value
    }

    /// Semantic-ish compare: `1.0.10` > `1.0.9`. Non-numeric tails compare as strings.
    static func isRemoteVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = normalizedVersion(remote)
        let l = normalizedVersion(local)
        if r == l { return false }
        return compareVersions(r, l) == .orderedDescending
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            let result = compareVersionComponent(a, b)
            if result != .orderedSame {
                return result
            }
        }
        return .orderedSame
    }

    /// `1.0.10` > `1.0.9`. A hyphen suffix is a pre-release: `1.0.35-beta` < `1.0.35`.
    private static func compareVersionComponent(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let (leftNumber, leftSuffix) = splitPreRelease(lhs)
        let (rightNumber, rightSuffix) = splitPreRelease(rhs)
        if leftNumber != rightNumber {
            if let ai = Int(leftNumber), let bi = Int(rightNumber), ai != bi {
                return ai < bi ? .orderedAscending : .orderedDescending
            }
            let result = leftNumber.compare(rightNumber, options: .numeric)
            if result != .orderedSame { return result }
        }
        switch (leftSuffix, rightSuffix) {
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        case let (left?, right?):
            return left.compare(right, options: .numeric)
        }
    }

    private static func splitPreRelease(_ part: String) -> (String, String?) {
        guard let dash = part.firstIndex(of: "-") else { return (part, nil) }
        let number = String(part[..<dash])
        let suffix = String(part[part.index(after: dash)...])
        guard !number.isEmpty, !suffix.isEmpty else { return (part, nil) }
        return (number, suffix)
    }
}
