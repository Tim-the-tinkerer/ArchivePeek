import Foundation

enum AppInfo {
    static let name = "ArchivePeek"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.22"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "23"
    }

    static var versionLabel: String {
        "\(version) (\(build))"
    }
}