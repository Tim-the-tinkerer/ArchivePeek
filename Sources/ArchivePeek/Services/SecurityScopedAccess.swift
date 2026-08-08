import Foundation

enum SecurityScopedAccess {
    final class Token: @unchecked Sendable {
        let url: URL
        private let bookmark: Data?
        private let lock = NSLock()
        private var accessCount = 0

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
            if resolvedURL().startAccessingSecurityScopedResource() {
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
                resolvedURL().stopAccessingSecurityScopedResource()
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
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ArchiveError.entryNotFound(url.lastPathComponent)
            }
            if !fileManager.isReadableFile(atPath: url.path) {
                throw ArchiveError.permissionDenied(url.lastPathComponent)
            }
        }
    }

    static func releaseAll(_ tokens: inout [Token]) {
        deactivate(tokens)
        tokens.removeAll()
    }

    static func removeToken(for url: URL, from tokens: inout [Token]) {
        let standardized = url.standardizedFileURL
        let matching = tokens.filter { $0.url == standardized }
        deactivate(matching)
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