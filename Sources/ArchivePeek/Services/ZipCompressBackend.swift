import Foundation

enum ZipCompressBackend {
    static func compress(
        sources: [URL],
        to archive: URL,
        compressionLevel: Int,
        handle: ProcessRunner.Handle? = nil,
        beforeCommit: ((URL) throws -> Void)? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let zip = ToolLocator.zipPath else {
            throw ArchiveError.toolUnavailable("zip")
        }

        onProgress?(CompressionProgressUpdate(
            fraction: 0,
            message: "Preparing files…",
            indeterminate: true
        ))

        // Stage in-process first (same as 7z) so security-scoped / external-volume
        // sources are fully readable and project files (.git, .gitignore, etc.) are kept.
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        let staged = try CompressionSupport.stageForSevenZip(
            sources,
            onProgress: onProgress,
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

        let destination = CompressionSupport.compressionDestination(
            archive: archive,
            sources: sources,
            format: .zip
        )
        var didFinalize = false
        defer {
            if !didFinalize {
                CompressionSupport.cleanupCompressionDestination(destination)
            }
        }
        try CompressionSupport.removeStaleNestedArchives(archive: destination.finalURL, sources: sources)

        let context = try CompressionSupport.zipContext(for: workSources)
        try FileManager.default.createDirectory(
            at: destination.workURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let level = min(max(compressionLevel, 0), 9)
        var arguments = ["-\(level)"]
        if CompressionSupport.sourcesIncludeDirectory(workSources) {
            arguments.append("-r")
        }
        arguments.append(destination.workURL.standardizedFileURL.path)
        arguments.append(contentsOf: context.itemNames)
        for pattern in CompressionSupport.zipExclusionPatterns(
            archive: destination.finalURL,
            sources: workSources,
            context: context
        ) {
            arguments.append("-x")
            arguments.append(pattern)
        }

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let parser = ZipProgressParser()
        let result = try ProcessRunner.runMonitored(
            executable: zip,
            arguments: arguments,
            workingDirectory: context.workingDirectory,
            environment: ["COPYFILE_DISABLE": "1"],
            handle: handle,
            onOutputChunk: { chunk in
                if let update = parser.ingest(chunk) {
                    onProgress?(update)
                }
            }
        )

        if result.wasCancelled {
            throw ArchiveError.cancelled
        }

        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "zip compression failed" : message)
        }

        // Strip junk from the temp work file before commit so finalization stays atomic.
        try CompressionSupport.stripMacJunkFromZip(at: destination.workURL)
        onProgress?(CompressionProgressUpdate(fraction: 0.98, message: "Saving archive…", indeterminate: true))
        try CompressionSupport.finalizeCompressionDestination(destination, beforeCommit: beforeCommit)
        didFinalize = true

        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…"))

        guard CompressionSupport.existingArchiveOutput(
            intended: destination.finalURL,
            format: .zip
        ) != nil else {
            throw ArchiveError.commandFailed("Archive was not created.")
        }
    }
}