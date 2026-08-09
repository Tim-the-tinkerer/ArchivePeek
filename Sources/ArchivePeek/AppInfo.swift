import Foundation

enum AppInfo {
    static let name = "ArchivePeek"

    /// Public project home and release source for Check for Updates.
    static let githubRepositoryURL = URL(string: "https://github.com/Tim-the-tinkerer/ArchivePeek")!
    static let githubReleasesURL = URL(string: "https://github.com/Tim-the-tinkerer/ArchivePeek/releases")!
    static let githubLatestReleaseAPIURL = URL(string: "https://api.github.com/repos/Tim-the-tinkerer/ArchivePeek/releases/latest")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.26"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "27"
    }

    static var versionLabel: String {
        "\(version) (\(build))"
    }
}