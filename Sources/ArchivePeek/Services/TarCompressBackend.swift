import Foundation

enum TarCompressBackend {
    static func compress(
        sources: [URL],
        to archive: URL,
        format: CompressFormat,
        handle: ProcessRunner.Handle? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let bsdtar = ToolLocator.bsdtarPath else {
            throw ArchiveError.toolUnavailable("bsdtar")
        }
        guard format.isTarFamily else {
            throw ArchiveError.unsupportedFormat
        }

        onProgress?(CompressionProgressUpdate(
            fraction: 0,
            message: "Compressing…",
            indeterminate: true
        ))

        let destination = CompressionSupport.compressionDestination(
            archive: archive,
            sources: sources,
            format: format
        )
        try CompressionSupport.removeStaleNestedArchives(archive: destination.finalURL, sources: sources)

        let context = try CompressionSupport.zipContext(for: sources)
        try FileManager.default.createDirectory(
            at: destination.workURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var arguments = ["-c"]
        if !format.bsdtarCompressionFlag.isEmpty {
            arguments.append(format.bsdtarCompressionFlag)
        }
        arguments.append(contentsOf: ["-f", destination.workURL.path])
        for pattern in CompressionSupport.macMetadataZipExclusions {
            arguments.append("--exclude")
            arguments.append(pattern)
        }
        arguments.append("-C")
        arguments.append(context.workingDirectory.path)
        arguments.append(contentsOf: context.itemNames)

        let parser = TarProgressParser()
        let result = try ProcessRunner.runMonitored(
            executable: bsdtar,
            arguments: arguments,
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
            throw ArchiveError.commandFailed(message.isEmpty ? "bsdtar compression failed" : message)
        }

        try CompressionSupport.finalizeCompressionDestination(destination)

        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))

        guard FileManager.default.fileExists(atPath: destination.finalURL.path) else {
            throw ArchiveError.commandFailed("Archive was not created.")
        }
    }
}