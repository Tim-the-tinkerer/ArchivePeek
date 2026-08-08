import Foundation

final class SevenZipProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction: Double = 0
    private var message = "Compressing…"
    private var indeterminate = true
    private var totalFiles: Int?
    private var processedFiles = 0

    var snapshot: (fraction: Double, message: String, indeterminate: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (fraction, message, indeterminate)
    }

    /// Parse a 7-Zip output chunk and return the latest progress snapshot when anything changed.
    func ingest(_ chunk: String) -> CompressionProgressUpdate? {
        let normalized = chunk.replacingOccurrences(of: "\r", with: "\n")
        var changed = false
        for line in normalized.split(whereSeparator: \.isNewline) {
            if processLine(String(line)) {
                changed = true
            }
        }
        guard changed else { return nil }
        let snap = snapshot
        return CompressionProgressUpdate(
            fraction: snap.fraction,
            message: snap.message,
            indeterminate: snap.indeterminate
        )
    }

    @discardableResult
    private func processLine(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let percent = Self.parsePercent(trimmed) {
            indeterminate = false
            fraction = max(fraction, Double(percent) / 100.0)
            message = "Compressing… \(percent)%"
            return true
        }

        if trimmed.hasPrefix("Scanning the drive:") {
            indeterminate = true
            message = "Compressing…"
            return true
        }

        if let summary = Self.parseScanSummary(trimmed) {
            totalFiles = summary.files
            indeterminate = true
            message = "Compressing \(summary.files) file\(summary.files == 1 ? "" : "s") (\(summary.sizeLabel))…"
            return true
        }

        if trimmed.hasPrefix("Creating archive:") {
            indeterminate = true
            message = "Compressing…"
            return true
        }

        if trimmed.hasPrefix("Add new data to archive:") {
            indeterminate = false
            fraction = max(fraction, 0.02)
            message = "Compressing…"
            return true
        }

        if trimmed.hasPrefix("+ ") {
            indeterminate = false
            processedFiles += 1
            let name = String(trimmed.dropFirst(2))
            // Prefer leaf name so long .build paths stay readable in the status line.
            let leaf = (name as NSString).lastPathComponent
            message = "Compressing \(leaf.isEmpty ? name : leaf)…"
            if let totalFiles, totalFiles > 0 {
                let ratio = min(1.0, Double(processedFiles) / Double(totalFiles))
                fraction = max(fraction, ratio * 0.98)
            } else {
                fraction = max(fraction, min(0.98, fraction + 0.005))
            }
            return true
        }

        return false
    }

    private static func parseScanSummary(_ text: String) -> (files: Int, sizeLabel: String)? {
        let filePattern = #"(\d+)\s+files?"#
        guard let regex = try? NSRegularExpression(pattern: filePattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let fileRange = Range(match.range(at: 1), in: text),
              let files = Int(text[fileRange]) else {
            return nil
        }

        let sizePattern = #"(\d+)\s+bytes"#
        var sizeLabel = ""
        if let sizeRegex = try? NSRegularExpression(pattern: sizePattern),
           let sizeMatch = sizeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let sizeRange = Range(sizeMatch.range(at: 1), in: text),
           let bytes = Int64(text[sizeRange]) {
            sizeLabel = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        if let parenRange = text.range(of: #"\([^)]+\)"#, options: .regularExpression) {
            sizeLabel = String(text[parenRange]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }

        return (files, sizeLabel.isEmpty ? "\(files) files" : sizeLabel)
    }

    private static func parsePercent(_ text: String) -> Int? {
        let percentPattern = #"(\d{1,3})\s*%"#
        if let regex = try? NSRegularExpression(pattern: percentPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let value = Int(text[range]), value <= 100 {
            return value
        }

        let digitsOnly = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(digitsOnly), value <= 100 {
            return value
        }
        return nil
    }
}