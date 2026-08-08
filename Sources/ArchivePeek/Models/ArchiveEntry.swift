import Foundation

struct ArchiveEntry: Identifiable, Hashable, Sendable {
    let path: String
    let isDirectory: Bool
    let uncompressedSize: Int64
    let compressedSize: Int64?
    let modified: Date?

    var id: String { path }

    var displayName: String {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (normalized as NSString).lastPathComponent
    }

    var parentPath: String {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (normalized as NSString).deletingLastPathComponent
    }

    var normalizedPath: String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

struct ArchiveListing: Equatable, Sendable {
    let format: String
    let entries: [ArchiveEntry]
    let archiveURL: URL
    let archiveSize: Int64
    let totalUncompressedSize: Int64
    let truncated: Bool
    let note: String?

    var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    var directoryCount: Int { entries.filter(\.isDirectory).count }

    var summary: String {
        var parts = [
            format,
            "\(fileCount) file\(fileCount == 1 ? "" : "s")",
            "\(directoryCount) folder\(directoryCount == 1 ? "" : "s")",
            ByteCountFormatter.string(fromByteCount: totalUncompressedSize, countStyle: .file) + " uncompressed",
        ]
        if truncated { parts.append("listing truncated") }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}