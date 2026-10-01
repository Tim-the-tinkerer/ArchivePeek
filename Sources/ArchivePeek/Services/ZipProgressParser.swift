import Foundation

final class ZipProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var processedFiles = 0

    func ingest(_ chunk: String) -> CompressionProgressUpdate? {
        let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
        var update: CompressionProgressUpdate?
        for line in normalized.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("adding:") || trimmed.hasPrefix("updating:") else { continue }

            lock.lock()
            processedFiles += 1
            let count = processedFiles
            lock.unlock()

            var name = trimmed
                .replacingOccurrences(of: "adding:", with: "")
                .replacingOccurrences(of: "updating:", with: "")
                .trimmingCharacters(in: .whitespaces)
            // zip appends the method and ratio, for example "(stored 0%)". That is not job progress.
            if let ratio = name.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
                name.removeSubrange(ratio)
                name = name.trimmingCharacters(in: .whitespaces)
            }

            update = CompressionProgressUpdate(
                fraction: min(0.98, Double(count) * 0.01),
                message: "Compressing \(name)…",
                indeterminate: count < 3
            )
        }
        return update
    }
}