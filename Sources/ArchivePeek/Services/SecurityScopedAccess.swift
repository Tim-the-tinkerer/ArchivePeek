import Foundation

enum SecurityScopedAccess {
    final class Token: @unchecked Sendable {
        let url: URL
        private let bookmark: Data?
        private let lock = NSLock()
        private var accessCount = 0
        /// The exact URL instance passed to `startAccessingSecurityScopedResource`.
        /// Must be the same object used for `stopAccessingSecurityScopedResource`.
        private var scopedURL: URL?

        init(url: URL, bookmark: Data?) {
            self.url = url.standardizedFileURL
            self.bookmark = bookmark
        }

        func resolvedURL() -> URL {
            guard let bookmark else { return url }
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return resolved.standardizedFileURL
            }
            return url
        }

        @discardableResult
        func beginAccess() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if accessCount > 0 {
                accessCount += 1
                return true
            }

            let resolved = resolvedURL()
            if resolved.startAccessingSecurityScopedResource() {
                scopedURL = resolved
                accessCount = 1
                return true
            }

            // Bookmark resolution can differ from the original panel URL; try original once.
            if resolved.path != url.path, url.startAccessingSecurityScopedResource() {
                scopedURL = url
                accessCount = 1
                return true
            }
            return false
        }

        func endAccess() {
            lock.lock()
            defer { lock.unlock() }
            guard accessCount > 0 else { return }
            accessCount -= 1
            if accessCount == 0 {
                scopedURL?.stopAccessingSecurityScopedResource()
                scopedURL = nil
            }
        }

        /// Drop every nested begin, always pairing stop with the started URL.
        func endAllAccess() {
            lock.lock()
            let shouldStop = accessCount > 0
            accessCount = 0
            let active = scopedURL
            scopedURL = nil
            lock.unlock()
            if shouldStop {
                active?.stopAccessingSecurityScopedResource()
            }
        }
    }

    @discardableResult
    static func begin(for urls: [URL]) -> [URL] {
        var accessed: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                accessed.append(url)
            }
        }
        return accessed
    }

    static func end(for urls: [URL]) {
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Capture bookmarks synchronously in an open/save panel or drop callback, before any async hop.
    static func captureTokens(for urls: [URL]) -> [Token] {
        urls.map { url in
            let standardized = url.standardizedFileURL
            return Token(url: standardized, bookmark: createBookmarkWhileAccessible(for: standardized))
        }
    }

    static func retainAccess(to url: URL, storage: inout [Token]) {
        let standardized = url.standardizedFileURL
        guard !storage.contains(where: { $0.url == standardized }) else { return }
        storage.append(Token(url: standardized, bookmark: createBookmarkWhileAccessible(for: standardized)))
    }

    static func retainAccess(to urls: [URL], storage: inout [Token]) {
        for url in urls {
            retainAccess(to: url, storage: &storage)
        }
    }

    @discardableResult
    static func activate(_ tokens: [Token]) -> Bool {
        guard !tokens.isEmpty else { return true }
        var acquiredAny = false
        for token in tokens {
            if token.beginAccess() {
                acquiredAny = true
            }
        }
        return acquiredAny
    }

    static func deactivate(_ tokens: [Token]) {
        for token in tokens {
            token.endAccess()
        }
    }

    static func validateReadable(_ urls: [URL]) throws {
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) || isSymlink
            guard exists else {
                throw ArchiveError.entryNotFound(url.lastPathComponent)
            }
            // isReadableFile is flaky for directories on some volumes; accept search (x) bit too.
            if isDirectory.boolValue {
                let readable = fileManager.isReadableFile(atPath: url.path)
                    || fileManager.isExecutableFile(atPath: url.path)
                if !readable {
                    throw ArchiveError.permissionDenied(url.lastPathComponent)
                }
            } else if isSymlink {
                // Link text is enough for staging; do not require the target to be readable.
                continue
            } else if !fileManager.isReadableFile(atPath: url.path) {
                throw ArchiveError.permissionDenied(url.lastPathComponent)
            }
        }
    }

    static func releaseAll(_ tokens: inout [Token]) {
        for token in tokens {
            token.endAllAccess()
        }
        tokens.removeAll()
    }

    static func removeToken(for url: URL, from tokens: inout [Token]) {
        let standardized = url.standardizedFileURL
        let matching = tokens.filter { $0.url == standardized }
        for token in matching {
            token.endAllAccess()
        }
        tokens.removeAll { $0.url == standardized }
    }

    static func resolvedURL(for source: URL, in tokens: [Token]) -> URL {
        let standardized = source.standardizedFileURL
        if let token = tokens.first(where: { $0.url == standardized }) {
            return token.resolvedURL()
        }
        return standardized
    }

    static func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func createBookmarkWhileAccessible(for url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return createBookmark(for: url)
    }
}
