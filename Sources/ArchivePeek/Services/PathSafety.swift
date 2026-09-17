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

    /// After extract, remove link members that resolve outside `destination`.
    static func enforceExtractContainment(
        in destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let base = destination.resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path
        guard let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        var escaped: [URL] = []
        for case let url as URL in enumerator {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let resolved = isLink
                ? url.resolvingSymlinksInPath().standardizedFileURL
                : url.standardizedFileURL
            if resolved.path == basePath || resolved.path.hasPrefix(basePath + "/") {
                continue
            }
            escaped.append(url)
        }
        for url in escaped {
            try? fileManager.removeItem(at: url)
        }
        if !escaped.isEmpty {
            throw ArchiveError.invalidEntryPath(escaped[0].lastPathComponent)
        }
    }

    /// Next unused directory `parent/base`, then `parent/base 2`, …
    static func uniqueChildDirectory(
        named base: String,
        in parent: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Archive" : trimmed
        let first = parent.appendingPathComponent(name, isDirectory: true)
        if !fileManager.fileExists(atPath: first.path) {
            return first
        }
        for n in 2...9_999 {
            let candidate = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}