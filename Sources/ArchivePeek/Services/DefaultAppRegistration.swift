import AppKit
import ApplicationServices
import UniformTypeIdentifiers

enum DefaultAppRegistration {
    static let archiveTypeIdentifier = "com.archivepeek.archive"
    /// Openable in ArchivePeek but excluded from default-app registration (disk images have their own handlers).
    static let excludedDefaultExtensions: Set<String> = ["dmg", "iso"]

    struct RegistrationResult {
        let succeeded: Bool
    }

    static var exportedArchiveType: UTType? {
        UTType(archiveTypeIdentifier)
    }

    static func isDefaultForArchives() -> Bool {
        isDefaultApplication(for: exportedArchiveType)
    }

    static func defaultApplicationSummary() -> String {
        if isDefaultForArchives() {
            return "ArchivePeek is the default app for archives."
        }
        return "ArchivePeek is not the default app for archives."
    }

    /// Re-register this app’s Info.plist types with Launch Services (exported UTIs, document roles).
    /// Call on launch so an older `/Applications/ArchivePeek.app` does not keep stale extension maps
    /// (e.g. `.cbz` under the generic archive type, which produced wrong Finder icons).
    static func registerBundleWithLaunchServices() {
        let appURL = Bundle.main.bundleURL as CFURL
        LSRegisterURL(appURL, true)
    }

    static func setAsDefaultArchiveApplication() -> RegistrationResult {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return RegistrationResult(succeeded: false)
        }

        registerBundleWithLaunchServices()

        let status = LSSetDefaultRoleHandlerForContentType(
            archiveTypeIdentifier as CFString,
            LSRolesMask.all,
            bundleID as CFString
        )

        return RegistrationResult(succeeded: status == noErr)
    }

    private static func isDefaultApplication(for type: UTType?) -> Bool {
        guard let type,
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            return false
        }
        return matchesCurrentApp(appURL)
    }

    private static func matchesCurrentApp(_ url: URL) -> Bool {
        if url.path == Bundle.main.bundleURL.path { return true }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier,
              let currentID = Bundle.main.bundleIdentifier else {
            return false
        }
        return bundleID == currentID
    }
}