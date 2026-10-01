import AppKit
import ApplicationServices
import UniformTypeIdentifiers

package enum DefaultAppRegistration {
    static let archiveTypeIdentifier = "com.archivepeek.archive"
    /// Openable in ArchivePeek but excluded from default-app registration (disk images have their own handlers).
    static let excludedDefaultExtensions: Set<String> = ["dmg", "iso"]

    struct RegistrationResult {
        let succeeded: Bool
    }

    static var exportedArchiveType: UTType? {
        UTType(archiveTypeIdentifier)
    }

    static func claimedDefaultTypeIdentifiers() -> [String] {
        var identifiers: Set<String> = [
            archiveTypeIdentifier,
            "com.archivepeek.cbz",
            "public.zip-archive",
            "public.tar-archive",
        ]
        for ext in ArchiveFormatCatalog.allExtensions where !excludedDefaultExtensions.contains(ext) {
            guard let type = UTType(filenameExtension: ext) else { continue }
            // .odt / .epub and similar resolve to document or book types. Claiming those
            // would take them from their editors. Only claim archive types and our own UTIs.
            if type.identifier == archiveTypeIdentifier || type.identifier == "com.archivepeek.cbz" {
                identifiers.insert(type.identifier)
                continue
            }
            if type.conforms(to: .archive) || type.conforms(to: .zip) {
                identifiers.insert(type.identifier)
            }
        }
        return Array(identifiers)
    }

    static func isDefaultForArchives() -> Bool {
        // The private UTI is one this app exports, so Launch Services names ArchivePeek for it
        // even when ZIP and the other shared types still open elsewhere.
        isDefaultApplication(for: .zip)
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
    package static func registerBundleWithLaunchServices() {
        let appURL = Bundle.main.bundleURL as CFURL
        LSRegisterURL(appURL, true)
    }

    static func setAsDefaultArchiveApplication() -> RegistrationResult {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return RegistrationResult(succeeded: false)
        }

        registerBundleWithLaunchServices()

        var sharedSucceeded = false
        for identifier in claimedDefaultTypeIdentifiers() {
            let status = LSSetDefaultRoleHandlerForContentType(
                identifier as CFString,
                LSRolesMask.all,
                bundleID as CFString
            )
            if status == noErr && !identifier.hasPrefix("com.archivepeek.") {
                sharedSucceeded = true
            }
        }

        return RegistrationResult(succeeded: sharedSucceeded)
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