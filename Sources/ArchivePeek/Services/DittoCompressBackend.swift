import Foundation

enum DittoCompressBackend {
    static func compress(
        sources: [URL],
        to archive: URL,
        handle: ProcessRunner.Handle? = nil,
        beforeCommit: ((URL) throws -> Void)? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let ditto = ToolLocator.dittoPath else {
            throw ArchiveError.toolUnavailable("ditto")
        }
        guard sources.count == 1 else {
            throw ArchiveError.invalidSelection
        }

        onProgress?(CompressionProgressUpdate(
            fraction: 0,
            message: "Preparing files…",
            indeterminate: true
        ))

        // Stage in-process first so security-scoped / external-volume project trees
        // (including .git and other hidden files) are fully readable by ditto.
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        let staged = try CompressionSupport.stageForSevenZip(
            sources,
            onProgress: onProgress,
            isCancelled: { handle?.wasCancelled == true }
        )
        defer { staged.cleanup() }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        guard staged.urls.count == 1 else {
            throw ArchiveError.invalidSelection
        }
        let source = staged.urls[0].standardizedFileURL

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
        try FileManager.default.createDirectory(
            at: destination.workURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)

        var arguments = ["-c", "-k", "--norsrc"]
        if isDirectory.boolValue {
            arguments.append("--keepParent")
        }
        arguments.append(source.path)
        arguments.append(destination.workURL.path)

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let result = try ProcessRunner.runMonitored(
            executable: ditto,
            arguments: arguments,
            handle: handle
        )

        if result.wasCancelled {
            throw ArchiveError.cancelled
        }

        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "ditto compression failed" : message)
        }

        try CompressionSupport.stripMacJunkFromZip(at: destination.workURL)
        onProgress?(CompressionProgressUpdate(fraction: 0.98, message: "Saving archive…", indeterminate: true))
        try CompressionSupport.finalizeCompressionDestination(destination, beforeCommit: beforeCommit)
        didFinalize = true

        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))

        guard FileManager.default.fileExists(atPath: destination.finalURL.path) else {
            throw ArchiveError.commandFailed("Archive was not created.")
        }
    }
}