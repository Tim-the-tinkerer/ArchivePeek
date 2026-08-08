import Foundation

final class ZipProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var processedFiles = 0

    func ingest(_ chunk: String) -> CompressionProgressUpdate? {
        let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("adding:") || trimmed.hasPrefix("updating:") else { continue }

            lock.lock()
            processedFiles += 1
            let count = processedFiles
            lock.unlock()

            let name = trimmed
                .replacingOccurrences(of: "adding:", with: "")
                .replacingOccurrences(of: "updating:", with: "")
                .trimmingCharacters(in: .whitespaces)

            return CompressionProgressUpdate(
                fraction: min(0.98, Double(count) * 0.01),
                message: "Compressing \(name)…",
                indeterminate: count < 3
            )
        }
        return nil
    }
}