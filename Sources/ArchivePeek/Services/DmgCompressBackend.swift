import Foundation

enum DmgCompressBackend {
    static func compress(
        sources: [URL],
        to archive: URL,
        compressionLevel: Int,
        password: String? = nil,
        appInstallerLayout: Bool = false,
        handle: ProcessRunner.Handle? = nil,
        beforeCommit: ((URL) throws -> Void)? = nil,
        onProgress: (@Sendable (CompressionProgressUpdate) -> Void)? = nil
    ) throws {
        guard let hdiutil = ToolLocator.hdiutilPath else {
            throw ArchiveError.toolUnavailable("hdiutil")
        }

        onProgress?(CompressionProgressUpdate(
            fraction: 0,
            message: "Creating disk image…",
            indeterminate: true
        ))

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let destination = CompressionSupport.compressionDestination(
            archive: archive,
            sources: sources,
            format: .dmg
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

        if appInstallerLayout, CompressionSupport.applicationBundles(in: sources).isEmpty {
            throw ArchiveError.invalidSelection
        }

        // Multi-source staging uses lastPathComponent — reject collisions before overwrite.
        if sources.count > 1 || appInstallerLayout {
            try CompressionSupport.validateUniqueStagingBasenames(sources)
        }

        let staged = try stageSources(
            sources,
            appInstallerLayout: appInstallerLayout,
            isCancelled: { handle?.wasCancelled == true }
        )
        defer {
            if staged.shouldCleanup {
                try? FileManager.default.removeItem(at: staged.folder)
            }
        }

        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let level = min(max(compressionLevel, 0), 9)
        let outputBase = hdiutilOutputBase(for: destination.workURL)
        let volumeName = volumeName(for: destination.finalURL, sources: sources, appInstallerLayout: appInstallerLayout)

        var arguments = [
            "create",
            "-srcfolder", staged.folder.path,
            "-volname", volumeName,
            "-ov",
        ]

        if level == 0 {
            arguments.append(contentsOf: ["-format", "UDRO"])
        } else {
            arguments.append(contentsOf: [
                "-format", "UDZO",
                "-imagekey", "zlib-level=\(level)",
            ])
        }

        if let password, !password.isEmpty {
            arguments.append(contentsOf: ["-encryption", "AES-256", "-stdinpass"])
        }

        arguments.append(contentsOf: ["-o", outputBase])

        let stdin = password.flatMap { $0.isEmpty ? nil : Data(($0 + "\n").utf8) }
        let result = try ProcessRunner.runMonitored(
            executable: hdiutil,
            arguments: arguments,
            stdin: stdin,
            handle: handle
        )

        if result.wasCancelled {
            throw ArchiveError.cancelled
        }

        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "hdiutil compression failed" : message)
        }

        onProgress?(CompressionProgressUpdate(fraction: 0.98, message: "Saving archive…", indeterminate: true))
        try CompressionSupport.finalizeCompressionDestination(destination, beforeCommit: beforeCommit)
        didFinalize = true

        onProgress?(CompressionProgressUpdate(fraction: 1.0, message: "Finishing…", indeterminate: false))

        guard FileManager.default.fileExists(atPath: destination.finalURL.path) else {
            throw ArchiveError.commandFailed("Disk image was not created.")
        }
    }

    static func verify(
        at url: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws -> String {
        guard let hdiutil = ToolLocator.hdiutilPath else {
            throw ArchiveError.toolUnavailable("hdiutil")
        }

        var arguments = ["verify"]
        let stdin: Data?
        if let password, !password.isEmpty {
            arguments.append(contentsOf: ["-stdinpass"])
            stdin = Data((password + "\n").utf8)
        } else {
            stdin = nil
        }
        arguments.append(url.path)

        let result = try ProcessRunner.run(
            executable: hdiutil,
            arguments: arguments,
            stdin: stdin,
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }

        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "DMG verification failed" : message)
        }

        let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.localizedCaseInsensitiveContains("valid") {
            return "Integrity check passed."
        }
        return message.isEmpty ? "Integrity check passed." : message
    }

    private struct StagedSources {
        let folder: URL
        let shouldCleanup: Bool
    }

    private static func stageSources(
        _ sources: [URL],
        appInstallerLayout: Bool,
        isCancelled: (() -> Bool)? = nil
    ) throws -> StagedSources {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        if isCancelled?() == true { throw ArchiveError.cancelled }

        // hdiutil -srcfolder requires a directory. Always stage into a folder so:
        // • single files become a valid disk image payload
        // • multi-source and app-installer layouts share the same prepare path
        // • cancel can clean a dedicated staging tree
        let staging = try makeStagingDirectory()
        for source in standardized {
            if isCancelled?() == true {
                try? FileManager.default.removeItem(at: staging)
                throw ArchiveError.cancelled
            }
            let destination = staging.appendingPathComponent(source.lastPathComponent)
            try copyItem(from: source, to: destination)
        }

        if appInstallerLayout {
            try addApplicationsShortcut(to: staging)
        }

        return StagedSources(folder: staging, shouldCleanup: true)
    }

    private static func makeStagingDirectory() throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePeek-dmg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private static func addApplicationsShortcut(to folder: URL) throws {
        let applicationsLink = folder.appendingPathComponent("Applications")
        if FileManager.default.fileExists(atPath: applicationsLink.path) {
            // Never silently delete a real staged item named Applications.
            throw ArchiveError.commandFailed(
                "App installer layout needs a free top-level name \"Applications\" for the Applications folder shortcut. Rename or remove that item from the selection, then try again."
            )
        }
        try FileManager.default.createSymbolicLink(
            at: applicationsLink,
            withDestinationURL: URL(fileURLWithPath: "/Applications")
        )
    }

    private static func copyItem(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if let ditto = ToolLocator.dittoPath {
            let result = try ProcessRunner.run(
                executable: ditto,
                arguments: ["--norsrc", source.path, destination.path]
            )
            guard result.exitCode == 0 else {
                throw ArchiveError.commandFailed("Failed to stage \(source.lastPathComponent) for DMG creation.")
            }
            return
        }

        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func hdiutilOutputBase(for url: URL) -> String {
        let path = url.path
        if path.lowercased().hasSuffix(".dmg") {
            return String(path.dropLast(4))
        }
        return path
    }

    private static func volumeName(
        for archive: URL,
        sources: [URL],
        appInstallerLayout: Bool
    ) -> String {
        if appInstallerLayout,
           sources.count == 1,
           CompressionSupport.isApplicationBundle(sources[0]) {
            return sources[0].deletingPathExtension().lastPathComponent
        }

        let base = archive.deletingPathExtension().lastPathComponent
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Archive" : trimmed
    }
}