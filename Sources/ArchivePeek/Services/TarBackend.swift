import Foundation

enum TarBackend {
    private static let verboseLineRegex = try? NSRegularExpression(
        pattern: #"^[-bcdhlpswD][-rwxtsST]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3}\s+\d{1,2}\s+(?:\d{2}:\d{2}(?::\d{2})?|\d{4}))\s+(.+)$"#
    )

    static func canHandle(_ url: URL) -> Bool {
        ArchiveFormatCatalog.tarExtensions.contains(url.pathExtension.lowercased())
            || isCompressedTar(url)
    }

    static func list(
        at url: URL,
        maxEntries: Int,
        handle: ProcessRunner.Handle? = nil
    ) throws -> [ArchiveEntry] {
        guard let bsdtar = ToolLocator.bsdtarPath else {
            throw ArchiveError.toolUnavailable("bsdtar")
        }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let result = try ProcessRunner.run(
            executable: bsdtar,
            arguments: ["-tvf", url.path],
            environment: ["LC_ALL": "C"],
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "bsdtar listing failed" : message)
        }

        var entries: [ArchiveEntry] = []
        var skipped = 0
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let entry = parseTarLine(line) {
                entries.append(entry)
                if entries.count >= maxEntries { break }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                skipped += 1
            }
        }
        // A day-first date line used to be dropped while Extract All still unpacked the archive.
        if skipped > 0 {
            throw ArchiveError.commandFailed("bsdtar listing could not be read")
        }
        return entries
    }

    static func extract(
        entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool = true,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let bsdtar = ToolLocator.bsdtarPath else {
            throw ArchiveError.toolUnavailable("bsdtar")
        }

        try PathSafety.validateEntries(entries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries where !entry.isDirectory {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            var arguments = ["-xvf", archive.path, "-C", destination.path]
            if !preservePaths {
                let stripCount = entry.normalizedPath.split(separator: "/").count - 1
                if stripCount > 0 {
                    arguments.append(contentsOf: ["--strip-components", String(stripCount)])
                }
            }
            arguments.append("--")
            arguments.append(entry.path)

            let result = try ProcessRunner.run(
                executable: bsdtar,
                arguments: arguments,
                handle: handle
            )
            if result.wasCancelled { throw ArchiveError.cancelled }
            guard result.exitCode == 0 else {
                let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ArchiveError.commandFailed(message.isEmpty ? "bsdtar extraction failed" : message)
            }
        }
        try PathSafety.createExtractedDirectories(entries, in: destination, preservePaths: preservePaths)
    }

    static func extractAll(
        from archive: URL,
        to destination: URL,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let bsdtar = ToolLocator.bsdtarPath else {
            throw ArchiveError.toolUnavailable("bsdtar")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try ProcessRunner.run(
            executable: bsdtar,
            arguments: ["-xvf", archive.path, "-C", destination.path],
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "bsdtar extraction failed" : message)
        }
    }

    static func extractFolder(
        entry: ArchiveEntry,
        from archive: URL,
        to destination: URL,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let bsdtar = ToolLocator.bsdtarPath else {
            throw ArchiveError.toolUnavailable("bsdtar")
        }

        try PathSafety.validateArchiveEntryPath(entry.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let prefix = entry.normalizedPath
        guard !prefix.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        let result = try ProcessRunner.run(
            executable: bsdtar,
            arguments: ["-xvf", archive.path, "-C", destination.path, "--", prefix],
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "bsdtar folder extraction failed" : message)
        }
    }

    static func extractToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        handle: ProcessRunner.Handle? = nil
    ) throws -> URL {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        TempFileRegistry.registerExtractRoot(tempRoot)
        try extract(entries: [entry], from: archive, to: tempRoot, preservePaths: true, handle: handle)

        return try PathSafety.containedExtractedFile(entry.normalizedPath, in: tempRoot)
    }

    private static func isCompressedTar(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.contains(".tar.")
    }

    private static func parseTarLine(_ line: String) -> ArchiveEntry? {
        guard let regex = verboseLineRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let sizeRange = Range(match.range(at: 1), in: line),
              let dateRange = Range(match.range(at: 2), in: line),
              let pathRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        let size = Int64(line[sizeRange]) ?? 0
        let modified = parseTarDate(String(line[dateRange]))
        var path = String(line[pathRange]).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("->") { return nil }
        guard !path.isEmpty else { return nil }

        let typeFlag = line.first
        // Only a symlink line uses " -> ". A regular file may be named "foo -> bar.txt".
        if typeFlag == "l", let arrow = path.range(of: " -> ") {
            path = String(path[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // Hard links are "name link to target".
        if typeFlag == "h", let link = path.range(of: " link to ") {
            path = String(path[..<link.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard let normalized = PathSafety.normalizeListedPath(path) else { return nil }
        path = normalized

        if typeFlag == "l" || typeFlag == "h" || typeFlag == "p" {
            return ArchiveEntry(
                path: path,
                isDirectory: false,
                uncompressedSize: typeFlag == "l" || typeFlag == "p" ? 0 : size,
                compressedSize: nil,
                modified: modified,
                compressionMethod: nil
            )
        }

        let isDir = path.hasSuffix("/") || typeFlag == "d"
        if isDir && !path.hasSuffix("/") {
            path += "/"
        }

        return ArchiveEntry(
            path: path,
            isDirectory: isDir,
            uncompressedSize: isDir ? 0 : size,
            compressedSize: nil,
            modified: modified,
            compressionMethod: nil
        )
    }

    private static func parseTarDate(_ text: String) -> Date? {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = ["MMM d HH:mm:ss", "MMM d HH:mm", "MMM d yyyy"]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }
}