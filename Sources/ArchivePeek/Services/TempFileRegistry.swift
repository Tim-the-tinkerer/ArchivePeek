import Foundation

enum TempFileRegistry {
    private static let lock = NSLock()
    private static var roots: [URL] = []
    private static var previewRoot: URL?
    /// Cap retained extract/preview temp trees so long sessions do not fill the disk.
    private static let maxRoots = 32

    static func registerExtractRoot(_ root: URL) {
        lock.lock()
        roots.append(root)
        pruneOldestLocked(keeping: maxRoots)
        lock.unlock()
    }

    static func setPreviewRoot(_ root: URL) {
        lock.lock()
        if let previous = previewRoot, previous != root {
            removeRootLocked(previous)
        }
        previewRoot = root
        if !roots.contains(root) {
            roots.append(root)
        }
        pruneOldestLocked(keeping: maxRoots, preserve: previewRoot)
        lock.unlock()
    }

    static func cleanupAll() {
        lock.lock()
        let allRoots = roots
        roots.removeAll()
        previewRoot = nil
        lock.unlock()

        let fileManager = FileManager.default
        for root in allRoots {
            if fileManager.fileExists(atPath: root.path) {
                try? fileManager.removeItem(at: root)
            }
        }
    }

    private static func pruneOldestLocked(keeping limit: Int, preserve: URL? = nil) {
        guard roots.count > limit else { return }
        let preservePath = preserve?.path
        var index = 0
        while roots.count > limit, index < roots.count {
            let candidate = roots[index]
            if let preservePath, candidate.path == preservePath {
                index += 1
                continue
            }
            roots.remove(at: index)
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private static func removeRootLocked(_ root: URL) {
        roots.removeAll { $0 == root }
        try? FileManager.default.removeItem(at: root)
    }
}
