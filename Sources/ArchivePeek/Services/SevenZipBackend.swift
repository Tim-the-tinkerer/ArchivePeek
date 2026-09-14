import Foundation

enum SevenZipBackend {
    private static func passwordArguments(for password: String?) -> [String] {
        if let password, !password.isEmpty {
            return ["-p\(password)"]
        }
        // Prevent 7-Zip from blocking on an interactive "Enter password:" prompt.
        return ["-p-"]
    }

    private static func isPasswordRelatedFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("wrong password")
            || lower.contains("can not open encrypted")
            || lower.contains("cannot open encrypted")
            || (lower.contains("encrypted") && lower.contains("password"))
            || (lower.contains("headers error") && lower.contains("encrypted"))
    }

    private static func mapFailure(_ message: String, fallback: String) -> ArchiveError {
        if isPasswordRelatedFailure(message) {
            return .passwordRequired
        }
        let lower = message.lowercased()
        if lower.contains("cannot find volume")
            || lower.contains("can't find volume")
            || lower.contains("can not find volume")
            || lower.contains("unavailable volume")
            || (lower.contains("missing") && lower.contains("volume")) {
            return .commandFailed(
                "This split archive is missing one or more volumes. Keep every part (for example .001, .002) in the same folder as the first volume."
            )
        }
        return .commandFailed(message.isEmpty ? fallback : message)
    }

    static func verify(
        at url: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws -> String {
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }

        var arguments = ["t", "-y"]
        arguments.append(contentsOf: passwordArguments(for: password))
        arguments.append(url.path)

        let result = try ProcessRunner.run(executable: sevenZip, arguments: arguments, handle: handle)
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw mapFailure(message, fallback: "7-Zip integrity test failed")
        }

        let message = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.localizedCaseInsensitiveContains("everything is ok") {
            return "Integrity check passed."
        }
        return message.isEmpty ? "Integrity check passed." : message
    }

    static func list(
        at url: URL,
        maxEntries: Int,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws -> [ArchiveEntry] {
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        var arguments = ["l", "-slt", "-ba", "-bd", "-bb0"]
        arguments.append(contentsOf: passwordArguments(for: password))
        arguments.append(url.path)

        let result = try ProcessRunner.run(executable: sevenZip, arguments: arguments, handle: handle)
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw mapFailure(message, fallback: "7-Zip listing failed")
        }

        var entries = parseListing(result.stdout)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        return entries
    }

    static func extract(
        entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let outputDirectory = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        let mode = preservePaths ? "x" : "e"

        try PathSafety.validateEntries(entries)

        for entry in entries where !entry.isDirectory {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            var arguments = [mode, "-y"]
            arguments.append(contentsOf: passwordArguments(for: password))
            arguments.append(contentsOf: [archive.path, entry.path, "-o\(outputDirectory)"])

            let result = try ProcessRunner.run(executable: sevenZip, arguments: arguments, handle: handle)
            if result.wasCancelled { throw ArchiveError.cancelled }
            guard result.exitCode == 0 else {
                let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw mapFailure(message, fallback: "7-Zip extraction failed")
            }
        }
    }

    static func extractAll(
        from archive: URL,
        to destination: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputDirectory = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        var arguments = ["x", "-y"]
        arguments.append(contentsOf: passwordArguments(for: password))
        arguments.append(contentsOf: [archive.path, "-o\(outputDirectory)"])

        let result = try ProcessRunner.run(executable: sevenZip, arguments: arguments, handle: handle)
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw mapFailure(message, fallback: "7-Zip extraction failed")
        }
    }

    /// Add files/folders into an existing archive via a work copy, then atomically replace.
    static func add(
        sources: [URL],
        to archive: URL,
        archiveFolder: String,
        compressionLevel: Int,
        password: String?,
        handle: ProcessRunner.Handle? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let format = ArchiveFormatCatalog.mutationFormat(for: archive) else {
            throw ArchiveError.cannotModifyArchive(ArchiveFormatCatalog.mutationUnsupportedMessage(for: archive))
        }
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }
        guard !sources.isEmpty else {
            throw ArchiveError.invalidSelection
        }
        if !archiveFolder.isEmpty {
            try PathSafety.validateArchiveEntryPath(archiveFolder)
        }

        let archivePath = archive.standardizedFileURL.path
        for source in sources {
            if source.standardizedFileURL.path == archivePath {
                throw ArchiveError.commandFailed("Cannot add the open archive to itself.")
            }
        }
        if CompressionSupport.archiveIsInsideSourceTree(archive, sources: sources) {
            throw ArchiveError.archiveInsideSources
        }

        onProgress?(CompressionProgressUpdate(fraction: 0, message: "Preparing files…", indeterminate: true))
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let staged = try CompressionSupport.stageForSevenZip(
            sources,
            onProgress: { update in onProgress?(update) },
            isCancelled: { handle?.wasCancelled == true }
        )
        defer { staged.cleanup() }

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let nested = try nestStagedItems(staged.urls, under: archiveFolder)
        defer { nested.cleanup() }

        onProgress?(CompressionProgressUpdate(fraction: 0.08, message: "Copying archive…", indeterminate: true))
        let destination = try copyArchiveToWorkFile(archive, format: format, handle: handle)
        var didFinalize = false
        defer {
            if !didFinalize {
                CompressionSupport.cleanupCompressionDestination(destination)
            }
        }

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        var arguments = [
            "a",
            "-y",
            "-mx\(min(max(compressionLevel, 0), 9))",
            "-mmt=on",
            "-bb1",
            "-snl",
            "-snh",
            "-sse",
            "-r",
        ]
        if format == .sevenZip, let password, !password.isEmpty {
            arguments.append("-mhe=on")
        }
        if let password, !password.isEmpty {
            arguments.append(contentsOf: passwordArguments(for: password))
        }
        arguments.append(contentsOf: CompressionSupport.macMetadataSevenZipExclusions.map { "-xr!\($0)" })
        arguments.append(destination.workURL.path)
        arguments.append(contentsOf: nested.itemNames)

        CompressDiagnostics.log("7zz update add: \(CompressDiagnostics.redactedArgumentList(arguments))")
        onProgress?(CompressionProgressUpdate(fraction: 0.12, message: "Adding files…", indeterminate: true))

        let parser = SevenZipProgressParser()
        let result = try ProcessRunner.runMonitored(
            executable: sevenZip,
            arguments: arguments,
            workingDirectory: nested.workingDirectory,
            handle: handle,
            onOutputChunk: { chunk in
                if let update = parser.ingest(chunk) {
                    let mapped = 0.12 + min(max(update.fraction, 0), 1) * 0.80
                    onProgress?(CompressionProgressUpdate(
                        fraction: mapped,
                        message: update.message,
                        indeterminate: update.indeterminate
                    ))
                }
            }
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw mapFailure(message, fallback: "Could not add files to the archive")
        }

        if format == .zip {
            try CompressionSupport.stripMacJunkFromZip(at: destination.workURL)
        }

        onProgress?(CompressionProgressUpdate(fraction: 0.94, message: "Verifying archive…", indeterminate: true))
        try CompressionSupport.finalizeCompressionDestination(destination) { stagedURL in
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            _ = try verify(at: stagedURL, password: password, handle: handle)
        }
        didFinalize = true
        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))
    }

    /// Remove members from an existing archive via a work copy, then atomically replace.
    static func delete(
        paths: [String],
        from archive: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let format = ArchiveFormatCatalog.mutationFormat(for: archive) else {
            throw ArchiveError.cannotModifyArchive(ArchiveFormatCatalog.mutationUnsupportedMessage(for: archive))
        }
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }
        guard !paths.isEmpty else {
            throw ArchiveError.invalidSelection
        }
        for path in paths {
            try PathSafety.validateArchiveEntryPath(path)
        }

        onProgress?(CompressionProgressUpdate(fraction: 0, message: "Copying archive…", indeterminate: true))
        let destination = try copyArchiveToWorkFile(archive, format: format, handle: handle)
        var didFinalize = false
        defer {
            if !didFinalize {
                CompressionSupport.cleanupCompressionDestination(destination)
            }
        }

        let uniquePaths = orderedUniquePaths(paths)
        let batches = stride(from: 0, to: uniquePaths.count, by: 200).map {
            Array(uniquePaths[$0..<min($0 + 200, uniquePaths.count)])
        }

        for (index, batch) in batches.enumerated() {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            var arguments = ["d", "-y"]
            if let password, !password.isEmpty {
                arguments.append(contentsOf: passwordArguments(for: password))
            }
            arguments.append(destination.workURL.path)
            arguments.append(contentsOf: batch)

            CompressDiagnostics.log("7zz update delete batch \(index + 1)/\(batches.count)")
            let fraction = batches.count == 1
                ? 0.4
                : 0.15 + (Double(index) / Double(batches.count)) * 0.7
            onProgress?(CompressionProgressUpdate(
                fraction: fraction,
                message: "Removing items…",
                indeterminate: batches.count == 1
            ))

            let result = try ProcessRunner.run(
                executable: sevenZip,
                arguments: arguments,
                handle: handle
            )
            if result.wasCancelled { throw ArchiveError.cancelled }
            guard result.exitCode == 0 else {
                let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw mapFailure(message, fallback: "Could not remove items from the archive")
            }
        }

        if format == .zip {
            try CompressionSupport.stripMacJunkFromZip(at: destination.workURL)
        }

        onProgress?(CompressionProgressUpdate(fraction: 0.92, message: "Verifying archive…", indeterminate: true))
        try CompressionSupport.finalizeCompressionDestination(destination) { stagedURL in
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            _ = try verify(at: stagedURL, password: password, handle: handle)
        }
        didFinalize = true
        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))
    }

    private static func copyArchiveToWorkFile(
        _ archive: URL,
        format: CompressFormat,
        handle: ProcessRunner.Handle?
    ) throws -> CompressionSupport.CompressionDestination {
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        guard FileManager.default.isReadableFile(atPath: archive.path) else {
            throw ArchiveError.permissionDenied(archive.lastPathComponent)
        }
        let destination = CompressionSupport.temporaryCompressionDestination(
            archive: archive,
            format: format
        )
        do {
            try FileManager.default.copyItem(at: archive, to: destination.workURL)
        } catch {
            CompressionSupport.cleanupCompressionDestination(destination)
            throw ArchiveError.commandFailed(
                "Could not copy \(archive.lastPathComponent) to update it: \(error.localizedDescription)"
            )
        }
        return destination
    }

    private static func nestStagedItems(
        _ urls: [URL],
        under archiveFolder: String
    ) throws -> (workingDirectory: URL, itemNames: [String], cleanup: () -> Void) {
        if archiveFolder.isEmpty {
            let context = try CompressionSupport.compressionInvocation(for: urls, archive: urls[0])
            return (context.workingDirectory, context.itemNames, {})
        }

        try PathSafety.validateArchiveEntryPath(archiveFolder)
        let fileManager = FileManager.default
        let nestRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ArchivePeek-nest-\(UUID().uuidString)", isDirectory: true)
        let destFolder = nestRoot.appendingPathComponent(archiveFolder, isDirectory: true)
        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)

        for url in urls {
            let dest = destFolder.appendingPathComponent(url.lastPathComponent)
            do {
                try fileManager.moveItem(at: url, to: dest)
            } catch {
                try? fileManager.removeItem(at: nestRoot)
                throw error
            }
        }

        let first = archiveFolder.split(separator: "/").map(String.init).first ?? archiveFolder
        return (nestRoot, [first], { try? fileManager.removeItem(at: nestRoot) })
    }

    private static func orderedUniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let key = path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                result.append(path)
            }
        }
        return result
    }

    static func compress(
        sources: [URL],
        to archive: URL,
        format: CompressFormat,
        compressionLevel: Int,
        password: String?,
        solidArchive: Bool = false,
        volumeArgument: String? = nil,
        handle: ProcessRunner.Handle? = nil,
        beforeCommit: ((URL) throws -> Void)? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }

        if format.requiresSingleFile {
            var isDirectory: ObjCBool = false
            let isSingleFile = sources.count == 1
                && FileManager.default.fileExists(atPath: sources[0].path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
            guard isSingleFile else {
                throw ArchiveError.commandFailed("\(format.label) archives can only contain a single file.")
            }
        }

        onProgress?(CompressionProgressUpdate(
            fraction: 0,
            message: "Preparing files…",
            indeterminate: true
        ))

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let staged = try CompressionSupport.stageForSevenZip(
            sources,
            onProgress: { update in onProgress?(update) },
            isCancelled: { handle?.wasCancelled == true }
        )
        defer { staged.cleanup() }

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let workSources = staged.urls

        onProgress?(CompressionProgressUpdate(
            fraction: 0.05,
            message: "Compressing…",
            indeterminate: true
        ))

        let destination = CompressionSupport.temporaryCompressionDestination(
            archive: archive,
            format: format
        )
        // Always build in a temp file; remove it on cancel/failure (success moves it away).
        var didFinalize = false
        defer {
            if !didFinalize {
                CompressionSupport.cleanupCompressionDestination(destination)
            }
        }

        let context = try CompressionSupport.compressionInvocation(for: workSources, archive: destination.workURL)
        try FileManager.default.createDirectory(at: context.workingDirectory, withIntermediateDirectories: true)

        var arguments = [
            "a",
            "-t\(format.sevenZipType)",
            "-y",
            "-mx\(min(max(compressionLevel, 0), 9))",
            "-mmt=on",
            "-bb1",
            "-snl",
            "-snh",
            "-sse",
        ]

        if CompressionSupport.sourcesIncludeDirectory(workSources) {
            arguments.append("-r")
        }

        if format == .sevenZip {
            arguments.append(solidArchive ? "-ms=on" : "-ms=off")
        }

        if let volumeArgument, !volumeArgument.isEmpty {
            arguments.append("-v\(volumeArgument)")
        }

        if let password, !password.isEmpty, format.supportsPassword {
            arguments.append("-p\(password)")
            if format == .sevenZip {
                arguments.append("-mhe=on")
            }
        }

        arguments.append(contentsOf: CompressionSupport.macMetadataSevenZipExclusions.map { "-xr!\($0)" })

        arguments.append(destination.workURL.path)
        arguments.append(contentsOf: context.itemNames)

        CompressDiagnostics.log("7zz path: \(sevenZip)")
        // Never write -pPASSWORD into compress.log.
        CompressDiagnostics.log("7zz args: \(CompressDiagnostics.redactedArgumentList(arguments))")
        CompressDiagnostics.log("7zz starting (large trees / solid+max can take a minute)…")

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        // Live chunks via ProcessRunner readabilityHandler (not readDataToEndOfFile).
        let parser = SevenZipProgressParser()
        let result = try ProcessRunner.runMonitored(
            executable: sevenZip,
            arguments: arguments,
            workingDirectory: context.workingDirectory,
            handle: handle,
            onOutputChunk: { chunk in
                if let update = parser.ingest(chunk) {
                    // Map 7z 0…1 into the remaining 0.05…0.95 band after prepare.
                    let mapped = 0.05 + min(max(update.fraction, 0), 1) * 0.90
                    onProgress?(CompressionProgressUpdate(
                        fraction: mapped,
                        message: update.message,
                        indeterminate: update.indeterminate
                    ))
                }
            }
        )

        if result.wasCancelled {
            CompressDiagnostics.log("7zz cancelled")
            throw ArchiveError.cancelled
        }

        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            CompressDiagnostics.log("7zz failed exit=\(result.exitCode): \(message)")
            if result.exitCode == 9 {
                throw ArchiveError.commandFailed(
                    "7-Zip could not run (macOS blocked the helper). Quit and reopen ArchivePeek, or install 7-Zip with Homebrew."
                )
            }
            throw ArchiveError.commandFailed(message.isEmpty ? "7-Zip compression failed (exit \(result.exitCode))" : message)
        }
        CompressDiagnostics.log("7zz finished exit=0")

        let workVolumes = CompressionSupport.createdVolumes(fromWorkBase: destination.workURL)
        let isSplit = volumeArgument != nil && (workVolumes.count > 1
            || workVolumes.contains { $0.path.lowercased().hasSuffix(".001") })

        if isSplit {
            guard !workVolumes.isEmpty else {
                throw ArchiveError.commandFailed("Split archive volumes were not created.")
            }
            CompressDiagnostics.log("committing \(workVolumes.count) split volume(s) next to \(destination.finalURL.lastPathComponent)")
            onProgress?(CompressionProgressUpdate(fraction: 0.98, message: "Saving volumes…", indeterminate: true))
            let committed = try CompressionSupport.finalizeSplitVolumes(
                workBase: destination.workURL,
                workVolumes: workVolumes,
                finalBase: destination.finalURL,
                beforeCommit: beforeCommit
            )
            didFinalize = true
            CompressDiagnostics.log("split archive saved")
            onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))
            guard !committed.isEmpty else {
                throw ArchiveError.commandFailed("Split archive was not saved to the chosen location.")
            }
            return
        }

        let createdWorkURL = CompressionSupport.existingArchiveOutput(
            intended: destination.workURL,
            format: format
        ) ?? destination.workURL
        guard FileManager.default.fileExists(atPath: createdWorkURL.path) else {
            throw ArchiveError.commandFailed("Archive was not created.")
        }

        var relocation = destination
        if createdWorkURL != destination.workURL {
            relocation = CompressionSupport.CompressionDestination(
                workURL: createdWorkURL,
                finalURL: destination.finalURL,
                shouldRelocate: destination.shouldRelocate
            )
        }
        // Junk strip and verify-before-commit run on work/sibling, never after replacing final.
        if format == .zip {
            try CompressionSupport.stripMacJunkFromZip(at: relocation.workURL)
        }
        CompressDiagnostics.log("committing archive to \(destination.finalURL.path)")
        onProgress?(CompressionProgressUpdate(fraction: 0.98, message: "Saving archive…", indeterminate: true))
        try CompressionSupport.finalizeCompressionDestination(relocation, beforeCommit: beforeCommit)
        didFinalize = true
        CompressDiagnostics.log("archive saved")

        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))

        guard CompressionSupport.existingArchiveOutput(
            intended: destination.finalURL,
            format: format
        ) != nil else {
            throw ArchiveError.commandFailed("Archive was not saved to the chosen location.")
        }
    }

    static func extractFolder(
        entry: ArchiveEntry,
        from archive: URL,
        to destination: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let sevenZip = ToolLocator.sevenZipPath else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }

        try PathSafety.validateArchiveEntryPath(entry.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let outputDirectory = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        let prefix = entry.normalizedPath
        guard !prefix.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        var arguments = ["x", "-y"]
        arguments.append(contentsOf: passwordArguments(for: password))
        arguments.append(contentsOf: [archive.path, "\(prefix)/*", "-o\(outputDirectory)"])

        let result = try ProcessRunner.run(executable: sevenZip, arguments: arguments, handle: handle)
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw mapFailure(message, fallback: "7-Zip folder extraction failed")
        }
    }

    static func extractToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws -> URL {
        let tempRoot = fileManagerTemporaryDirectory()
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        TempFileRegistry.registerExtractRoot(tempRoot)
        try extract(
            entries: [entry],
            from: archive,
            to: tempRoot,
            preservePaths: true,
            password: password,
            handle: handle
        )

        let extracted = try PathSafety.resolvedURL(forEntryPath: entry.normalizedPath, in: tempRoot)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw ArchiveError.entryNotFound(entry.path)
        }
        return extracted
    }

    private static func fileManagerTemporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func parseListing(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var currentPath: String?
        var currentSize: Int64 = 0
        var currentPackedSize: Int64?
        var currentIsDirectory = false
        var sawAttributes = false
        var currentModified: Date?

        func resetCurrent() {
            currentPath = nil
            currentSize = 0
            currentPackedSize = nil
            currentIsDirectory = false
            sawAttributes = false
            currentModified = nil
        }

        func flush() {
            guard let path = currentPath, !path.isEmpty, sawAttributes else {
                resetCurrent()
                return
            }
            entries.append(
                ArchiveEntry(
                    path: currentIsDirectory && !path.hasSuffix("/") ? path + "/" : path,
                    isDirectory: currentIsDirectory,
                    uncompressedSize: currentSize,
                    compressedSize: currentPackedSize,
                    modified: currentModified
                )
            )
            resetCurrent()
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == "--" { continue }
            if line.hasPrefix("Path = ") {
                flush()
                currentPath = String(line.dropFirst("Path = ".count))
                continue
            }
            if line.hasPrefix("Size = ") {
                currentSize = Int64(line.dropFirst("Size = ".count)) ?? 0
                continue
            }
            if line.hasPrefix("Packed Size = ") {
                currentPackedSize = Int64(line.dropFirst("Packed Size = ".count))
                continue
            }
            if line.hasPrefix("Modified = ") {
                let value = String(line.dropFirst("Modified = ".count))
                currentModified = parseSevenZipDate(value)
                continue
            }
            if line.hasPrefix("Attributes = ") {
                let attributes = String(line.dropFirst("Attributes = ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentIsDirectory = attributes == "D"
                    || attributes.hasPrefix("D_")
                    || attributes.hasPrefix("D ")
                    || attributes.contains(" D")
                sawAttributes = true
            }
        }

        flush()
        return entries
    }

    private static func parseSevenZipDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}