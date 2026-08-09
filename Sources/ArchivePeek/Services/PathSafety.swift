import Foundation

enum PathSafety {
    static func validateArchiveEntryPath(_ path: String) throws {
        // Reject embedded NULs (can confuse C APIs / archive tools).
        if path.utf8.contains(0) {
            throw ArchiveError.invalidEntryPath(path)
        }

        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else {
            throw ArchiveError.invalidEntryPath(path)
        }

        // Absolute / home-relative paths (Unix) and Windows drive / UNC-style.
        if normalized.hasPrefix("/") || normalized == "~" || normalized.hasPrefix("~/") {
            throw ArchiveError.invalidEntryPath(path)
        }
        if normalized.count >= 2,
           normalized[normalized.startIndex].isLetter,
           normalized[normalized.index(after: normalized.startIndex)] == ":" {
            throw ArchiveError.invalidEntryPath(path)
        }

        for component in normalized.split(separator: "/") {
            if component == ".." || component == "." {
                throw ArchiveError.invalidEntryPath(path)
            }
            // Reject NULs and other C0 controls (CR/LF/TAB can confuse tools and logs).
            if component.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw ArchiveError.invalidEntryPath(path)
            }
            // 7-Zip / unzip treat these as wildcards; reject so extract cannot expand unexpectedly.
            if component.contains("*") || component.contains("?") || component.contains("[") {
                throw ArchiveError.invalidEntryPath(path)
            }
        }
    }

    static func resolvedURL(forEntryPath path: String, in directory: URL) throws -> URL {
        try validateArchiveEntryPath(path)

        // Resolve symlinks on the base so containment checks are not fooled by a
        // destination directory that itself is a link outside the intended tree.
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = base.appendingPathComponent(path).standardizedFileURL
        let basePath = base.path
        let resolvedPath = resolved.path

        // Require path + "/" prefix (not bare prefix) so /tmp/foo cannot match /tmp/foobar.
        guard resolvedPath == basePath || resolvedPath.hasPrefix(basePath + "/") else {
            throw ArchiveError.invalidEntryPath(path)
        }

        return resolved
    }

    static func validateEntries(_ entries: [ArchiveEntry]) throws {
        for entry in entries {
            try validateArchiveEntryPath(entry.path)
        }
    }
}