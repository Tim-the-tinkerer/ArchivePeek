import Foundation

enum RarCompressBackend {
    static func compress(
        sources: [URL],
        to archive: URL,
        compressionLevel: Int,
        password: String?,
        solidArchive: Bool,
        volumeArgument: String? = nil,
        handle: ProcessRunner.Handle? = nil,
        beforeCommit: ((URL) throws -> Void)? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let rar = ToolLocator.rarPath else {
            throw ArchiveError.toolUnavailable("RAR")
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

        let destination = CompressionSupport.temporaryCompressionDestination(
            archive: archive,
            format: .rar
        )
        var didFinalize = false
        defer {
            if !didFinalize {
                CompressionSupport.cleanupCompressionDestination(destination)
            }
        }

        let context = try CompressionSupport.compressionInvocation(
            for: staged.urls,
            archive: destination.workURL
        )
        try FileManager.default.createDirectory(at: context.workingDirectory, withIntermediateDirectories: true)

        var arguments = [
            "a",
            "-y",
            "-r",
            "-ol",
            "-m\(CompressFormat.rarMethod(forCompressionLevel: compressionLevel))",
        ]
        arguments.append("-cfg-")
        arguments.append(solidArchive ? "-s" : "-s-")
        if let password, !password.isEmpty {
            arguments.append("-hp\(password)")
        }
        if let volumeArgument, !volumeArgument.isEmpty {
            arguments.append("-v\(volumeArgument)")
        }
        arguments.append(destination.workURL.path)
        arguments.append(contentsOf: context.itemNames)

        CompressDiagnostics.log("rar path: \(rar)")
        CompressDiagnostics.log("rar args: \(CompressDiagnostics.redactedArgumentList(arguments))")
        onProgress?(CompressionProgressUpdate(fraction: 0.08, message: "Compressing…", indeterminate: true))

        let result = try ProcessRunner.runMonitored(
            executable: rar,
            arguments: arguments,
            workingDirectory: context.workingDirectory,
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "RAR compression failed (exit \(result.exitCode))" : message)
        }

        let workVolumes = CompressionSupport.createdVolumes(fromWorkBase: destination.workURL)
        let isSplit = volumeArgument != nil && (
            workVolumes.count > 1
                || workVolumes.contains { $0.lastPathComponent.lowercased().contains(".part") }
        )

        onProgress?(CompressionProgressUpdate(fraction: 0.98, message: "Saving archive…", indeterminate: true))
        if isSplit {
            guard !workVolumes.isEmpty else {
                throw ArchiveError.commandFailed("Split RAR volumes were not created.")
            }
            let committed = try CompressionSupport.finalizeSplitVolumes(
                workBase: destination.workURL,
                workVolumes: workVolumes,
                finalBase: destination.finalURL,
                beforeCommit: beforeCommit
            )
            guard !committed.isEmpty else {
                throw ArchiveError.commandFailed("Split RAR volumes were not saved to the chosen location.")
            }
        } else {
            let created = CompressionSupport.existingArchiveOutput(
                intended: destination.workURL,
                format: .rar
            ) ?? destination.workURL
            guard FileManager.default.fileExists(atPath: created.path) else {
                throw ArchiveError.commandFailed("RAR archive was not created.")
            }
            var relocation = destination
            if created != destination.workURL {
                relocation = CompressionSupport.CompressionDestination(
                    workURL: created,
                    finalURL: destination.finalURL,
                    shouldRelocate: destination.shouldRelocate
                )
            }
            try CompressionSupport.finalizeCompressionDestination(relocation, beforeCommit: beforeCommit)
        }
        didFinalize = true
        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))

        if !isSplit {
            guard CompressionSupport.existingArchiveOutput(
                intended: destination.finalURL,
                format: .rar
            ) != nil else {
                throw ArchiveError.commandFailed("RAR archive was not saved to the chosen location.")
            }
        }
    }
}
