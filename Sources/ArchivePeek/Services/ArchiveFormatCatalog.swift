import Foundation
import UniformTypeIdentifiers

enum ArchiveFormatCatalog {
    static let zipExtensions: Set<String> = [
        "zip", "jar", "cbz", "epub", "apk", "war", "whl", "xpi", "vsix", "nbm", "kmz", "odt", "ods", "odp",
    ]

    static let sevenZipExtensions: Set<String> = ["7z"]

    static let rarExtensions: Set<String> = ["rar", "r00", "r01"]

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
        let ext = normalizedExtension(for: url)
        if allExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .zip) {
            return true
        }
        if url.lastPathComponent.lowercased().contains(".tar.") { return true }
        return false
    }

    static func formatLabel(for url: URL) -> String {
        let ext = normalizedExtension(for: url)
        if sevenZipExtensions.contains(ext) { return "7z" }
        if rarExtensions.contains(ext) { return "RAR" }
        if tarExtensions.contains(ext) || url.lastPathComponent.lowercased().contains(".tar.") { return "TAR" }
        if zipExtensions.contains(ext) { return "ZIP" }
        if singleFileCompressionExtensions.contains(ext) { return ext.uppercased() }
        return ext.isEmpty ? "Archive" : ext.uppercased()
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
        let ext = normalizedExtension(for: url)
        if zipExtensions.contains(ext) { return .zipNative }
        if TarBackend.canHandle(url) { return .tar }
        return .sevenZip
    }
}