import Foundation

enum TempFileRegistry {
    private static let lock = NSLock()
    private static var roots: [URL] = []
    private static var previewRoot: URL?

    static func registerExtractRoot(_ root: URL) {
        lock.lock()
        roots.append(root)
        lock.unlock()
    }

    static func setPreviewRoot(_ root: URL) {
        lock.lock()
        if let previous = previewRoot {
            removeRootLocked(previous)
        }
        previewRoot = root
        if !roots.contains(root) {
            roots.append(root)
        }
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

    private static func removeRootLocked(_ root: URL) {
        roots.removeAll { $0 == root }
        try? FileManager.default.removeItem(at: root)
    }
}