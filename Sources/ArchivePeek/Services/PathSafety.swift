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

    /// Listing text such as `./sub/f.txt` is the member `sub/f.txt`.
    /// A lone `.` is the archive root and is not a member. `..` is left in place so validation still rejects it.
    static func normalizeListedPath(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// Create folder members that have no files. File extraction does not make an empty directory.
    static func createExtractedDirectories(
        _ entries: [ArchiveEntry],
        in destination: URL,
        preservePaths: Bool
    ) throws {
        for entry in entries where entry.isDirectory {
            let name = preservePaths ? entry.normalizedPath : entry.displayName
            guard !name.isEmpty else { continue }
            let url = try resolvedURL(forEntryPath: name, in: destination)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func validateEntries(_ entries: [ArchiveEntry]) throws {
        for entry in entries {
            try validateArchiveEntryPath(entry.path)
        }
    }

    /// After extract, remove link members that resolve outside `destination`.
    /// Packages are walked too: a symlink inside a `.app` can still point outside.
    /// Directory symlinks are not followed; the link itself is checked.
    static func enforceExtractContainment(
        in destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let base = destination.resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path
        guard let enumerator = fileManager.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }

        var escaped: [URL] = []
        for case let url as URL in enumerator {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if isLink {
                if symlinkEscapes(url, basePath: basePath, fileManager: fileManager) {
                    escaped.append(url)
                }
                continue
            }
            let resolved = url.standardizedFileURL
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

    /// Temp extract used by Open, Quick Look, and drag-out.
    /// Runs containment first so a link to a file outside the temp tree is not opened.
    static func containedExtractedFile(_ entryPath: String, in root: URL) throws -> URL {
        try enforceExtractContainment(in: root)
        let extracted = try resolvedURL(forEntryPath: entryPath, in: root)
        let isLink = (try? extracted.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if isLink || FileManager.default.fileExists(atPath: extracted.path) {
            return extracted
        }
        throw ArchiveError.entryNotFound(entryPath)
    }

    /// True when the link text, including a dangling target, lands outside `basePath`.
    private static func symlinkEscapes(
        _ url: URL,
        basePath: String,
        fileManager: FileManager
    ) -> Bool {
        guard let linkText = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return true
        }
        if linkText.utf8.contains(0) { return true }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = linkText.hasPrefix("/")
            ? URL(fileURLWithPath: linkText)
            : parent.appendingPathComponent(linkText)
        let resolved = target.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        return !(path == basePath || path.hasPrefix(basePath + "/"))
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