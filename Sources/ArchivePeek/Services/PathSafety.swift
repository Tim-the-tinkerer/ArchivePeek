import Foundation

enum PathSafety {
    static func validateArchiveEntryPath(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else {
            throw ArchiveError.invalidEntryPath(path)
        }

        if normalized.hasPrefix("/") {
            throw ArchiveError.invalidEntryPath(path)
        }

        for component in normalized.split(separator: "/") {
            if component == ".." || component == "." {
                throw ArchiveError.invalidEntryPath(path)
            }
        }
    }

    static func resolvedURL(forEntryPath path: String, in directory: URL) throws -> URL {
        try validateArchiveEntryPath(path)

        let base = directory.standardizedFileURL
        let resolved = base.appendingPathComponent(path).standardizedFileURL
        let basePath = base.path
        let resolvedPath = resolved.path

        guard resolvedPath == basePath || resolvedPath.hasPrefix(basePath + "/") else {
            throw ArchiveError.invalidEntryPath(path)
        }

        return resolved
    }

    static func validateEntries(_ entries: [ArchiveEntry]) throws {
        for entry in entries where !entry.isDirectory {
            try validateArchiveEntryPath(entry.path)
        }
    }
}