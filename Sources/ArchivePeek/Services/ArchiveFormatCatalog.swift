import Foundation
import UniformTypeIdentifiers

enum ArchiveFormatCatalog {
    /// Dedicated comic-book ZIP type (exported in AppInfo.plist). Conforms to `public.zip-archive`.
    static let cbzTypeIdentifier = "com.archivepeek.cbz"

    static let zipExtensions: Set<String> = [
        "zip", "jar", "cbz", "epub", "apk", "war", "whl", "xpi", "vsix", "nbm", "kmz", "odt", "ods", "odp",
    ]

    static let sevenZipExtensions: Set<String> = ["7z"]

    static let rarExtensions: Set<String> = ["rar", "r00", "r01", "r02"]

    static let tarExtensions: Set<String> = ["tar", "tgz", "tbz", "tbz2", "txz", "tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    static let singleFileCompressionExtensions: Set<String> = ["gz", "bz2", "xz", "lzma", "zst"]

    static let otherSevenZipExtensions: Set<String> = [
        "cab", "iso", "cpio", "ar", "deb", "rpm", "lzh", "arj", "wim", "xar", "msi", "dmg", "lz", "lzma",
    ]

    static var allExtensions: Set<String> {
        zipExtensions
            .union(sevenZipExtensions)
            .union(rarExtensions)
            .union(tarExtensions)
            .union(singleFileCompressionExtensions)
            .union(otherSevenZipExtensions)
    }

    static func isArchive(_ url: URL) -> Bool {
        if SplitArchive.isSplitVolumeName(url.lastPathComponent) { return true }
        if SplitArchive.set(for: url)?.isMultiVolume == true { return true }
        let ext = normalizedExtension(for: url)
        if allExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .zip) {
            return true
        }
        if url.lastPathComponent.lowercased().contains(".tar.") { return true }
        return false
    }

    static func formatLabel(for url: URL) -> String {
        if let split = SplitArchive.set(for: url) {
            return split.formatLabel
        }
        let ext = normalizedExtension(for: url)
        if sevenZipExtensions.contains(ext) { return "7z" }
        if rarExtensions.contains(ext) { return "RAR" }
        if tarExtensions.contains(ext) || url.lastPathComponent.lowercased().contains(".tar.") { return "TAR" }
        if zipExtensions.contains(ext) { return "ZIP" }
        if singleFileCompressionExtensions.contains(ext) { return ext.uppercased() }
        return ext.isEmpty ? "Archive" : ext.uppercased()
    }

    static func canonicalArchiveURL(for url: URL) -> URL {
        SplitArchive.canonicalURL(for: url)
    }

    /// ZIP family and 7z can be updated via a work copy. Uncompressed TAR is excluded:
    /// 7-Zip cannot update POSIX PAX tars produced by macOS bsdtar (including ArchivePeek).
    static func supportsMutation(_ url: URL) -> Bool {
        mutationFormat(for: url) != nil
    }

    static func mutationFormat(for url: URL) -> CompressFormat? {
        if let split = SplitArchive.set(for: url), split.isMultiVolume || SplitArchive.isSplitVolumeName(url.lastPathComponent) {
            return nil
        }
        let ext = normalizedExtension(for: url)
        if zipExtensions.contains(ext) { return .zip }
        if sevenZipExtensions.contains(ext) { return .sevenZip }
        return nil
    }

    static func mutationUnsupportedMessage(for url: URL) -> String {
        let label = formatLabel(for: url)
        return "\(label) archives cannot be modified. Extract the contents and create a new archive instead."
    }

    /// Archive file name without the format suffix (`Report.tar.gz` → `Report`).
    static func displayBasename(for url: URL) -> String {
        if let split = SplitArchive.set(for: url) {
            let trimmed = split.displayStem.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return trimmed.isEmpty ? "Archive" : trimmed
        }
        let name = url.lastPathComponent
        let ext = normalizedExtension(for: url)
        var base = name
        if !ext.isEmpty {
            let suffix = "." + ext
            if name.lowercased().hasSuffix(suffix) {
                base = String(name.dropLast(suffix.count))
            }
        }
        let trimmed = base.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return trimmed.isEmpty ? "Archive" : trimmed
    }

    static func normalizedExtension(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"] {
            if name.hasSuffix(".\(compound)") { return compound }
        }
        return url.pathExtension.lowercased()
    }

    enum Backend {
        case zipNative
        case tar
        case sevenZip
    }

    static func preferredBackend(for url: URL) -> Backend {
        if SplitArchive.set(for: url) != nil { return .sevenZip }
        let ext = normalizedExtension(for: url)
        if zipExtensions.contains(ext) { return .zipNative }
        if TarBackend.canHandle(url) { return .tar }
        return .sevenZip
    }
}