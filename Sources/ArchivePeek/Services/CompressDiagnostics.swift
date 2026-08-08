import Foundation

enum CompressDiagnostics {
    private static let lock = NSLock()
    private static let logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ArchivePeek/compress.log")
    }()

    static var logFilePath: String { logURL.path }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "=== ArchivePeek compress log ===\n".write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
        fputs(line, stderr)
    }
}