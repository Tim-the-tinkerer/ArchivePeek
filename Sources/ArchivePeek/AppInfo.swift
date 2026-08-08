import Foundation

enum AppInfo {
    static let name = "ArchivePeek"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.10"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "11"
    }

    static var versionLabel: String {
        "\(version) (\(build))"
    }
}