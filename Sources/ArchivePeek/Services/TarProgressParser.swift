import Foundation

final class TarProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var announcedFiles = 0

    func ingest(_ chunk: String) -> CompressionProgressUpdate? {
        let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            lock.lock()
            announcedFiles += 1
            let count = announcedFiles
            lock.unlock()

            return CompressionProgressUpdate(
                fraction: min(0.98, Double(count) * 0.02),
                message: "Compressing \(trimmed)…",
                indeterminate: count < 3
            )
        }
        return nil
    }
}