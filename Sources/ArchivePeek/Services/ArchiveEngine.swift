import Foundation

enum ArchiveEngine {
    static let maxEntries = 10_000

    static func list(url: URL, password: String? = nil) async throws -> ArchiveListing {
        try await Task.detached(priority: .userInitiated) {
            try listSynchronously(url: url, password: password)
        }.value
    }

    static func extract(
        entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool = true,
        password: String? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try extractSynchronously(
                entries: entries,
                from: archive,
                to: destination,
                preservePaths: preservePaths,
                password: password
            )
        }.value
    }

    static func extractAll(
        from archive: URL,
        to destination: URL,
        password: String? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try extractAllSynchronously(from: archive, to: destination, password: password)
        }.value
    }

    static func extractToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        password: String? = nil,
        catalogEntries: [ArchiveEntry] = []
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try extractToTempSynchronously(
                entry: entry,
                from: archive,
                password: password,
                catalogEntries: catalogEntries
            )
        }.value
    }

    static func verifyIntegrity(
        url: URL,
        password: String? = nil,
        accessTokens: [SecurityScopedAccess.Token] = []
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard SecurityScopedAccess.activate(accessTokens) else {
                throw ArchiveError.permissionDenied(url.lastPathComponent)
            }
            defer { SecurityScopedAccess.deactivate(accessTokens) }
            return try verifyIntegritySynchronously(url: url, password: password)
        }.value
    }

    static func compress(
        sources: [URL],
        to archive: URL,
        format: CompressFormat,
        compressionLevel: Int = 5,
        password: String? = nil,
        solidArchive: Bool = false,
        dmgAppInstallerLayout: Bool = false,
        accessTokens: [SecurityScopedAccess.Token] = [],
        handle: ProcessRunner.Handle? = nil,
        onProgress: @escaping @Sendable (CompressionProgressUpdate) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try performCompress(
                sources: sources,
                to: archive,
                format: format,
                compressionLevel: compressionLevel,
                password: password,
                solidArchive: solidArchive,
                dmgAppInstallerLayout: dmgAppInstallerLayout,
                accessTokens: accessTokens,
                handle: handle,
                onProgress: onProgress
            )
        }.value
    }

    private static func performCompress(
        sources: [URL],
        to archive: URL,
        format: CompressFormat,
        compressionLevel: Int,
        password: String?,
        solidArchive: Bool,
        dmgAppInstallerLayout: Bool,
        accessTokens: [SecurityScopedAccess.Token],
        handle: ProcessRunner.Handle?,
        onProgress: @escaping @Sendable (CompressionProgressUpdate) -> Void
    ) throws {
        guard SecurityScopedAccess.activate(accessTokens) else {
            throw ArchiveError.permissionDenied("selected files")
        }
        defer { SecurityScopedAccess.deactivate(accessTokens) }

        let resolvedSources = sources.map {
            SecurityScopedAccess.resolvedURL(for: $0, in: accessTokens)
        }
        try SecurityScopedAccess.validateReadable(resolvedSources)
        CompressDiagnostics.log(
            "start format=\(format.label) sources=\(resolvedSources.count) tokens=\(accessTokens.count) sevenZip=\(ToolLocator.sevenZipPath ?? "nil")"
        )
        for source in resolvedSources {
            CompressDiagnostics.log("source: \(source.path)")
        }
        CompressDiagnostics.log("archive: \(archive.path)")

        let workSources = resolvedSources
        let statusMessage = CompressionSupport.compressStatusMessage(for: resolvedSources)
        onProgress(CompressionProgressUpdate(
            fraction: 0,
            message: statusMessage,
            indeterminate: true
        ))
        CompressDiagnostics.log("status: \(statusMessage)")

        let noPassword = password == nil || password?.isEmpty == true
        let useDitto = format == .zip
            && noPassword
            && workSources.count == 1
            && ToolLocator.dittoPath != nil
        let useNativeZip = format == .zip
            && noPassword
            && ToolLocator.zipPath != nil
        let useNativeTar = format.isTarFamily
            && noPassword
            && ToolLocator.bsdtarPath != nil
        let useDmg = format.isDmg && ToolLocator.hdiutilPath != nil

        if useDmg {
            try DmgCompressBackend.compress(
                sources: workSources,
                to: archive,
                compressionLevel: compressionLevel,
                password: password,
                appInstallerLayout: dmgAppInstallerLayout,
                handle: handle,
                onProgress: onProgress
            )
        } else if useDitto {
            try DittoCompressBackend.compress(
                sources: workSources,
                to: archive,
                handle: handle,
                onProgress: onProgress
            )
        } else if useNativeZip {
            try ZipCompressBackend.compress(
                sources: workSources,
                to: archive,
                compressionLevel: compressionLevel,
                handle: handle,
                onProgress: onProgress
            )
        } else if useNativeTar {
            try TarCompressBackend.compress(
                sources: workSources,
                to: archive,
                format: format,
                handle: handle,
                onProgress: onProgress
            )
        } else if format.isDmg {
            throw ArchiveError.toolUnavailable("hdiutil")
        } else {
            guard ToolLocator.isSevenZipAvailable else {
                throw ArchiveError.toolUnavailable("7-Zip")
            }
            try SevenZipBackend.compress(
                sources: workSources,
                to: archive,
                format: format,
                compressionLevel: compressionLevel,
                password: password,
                solidArchive: solidArchive,
                handle: handle,
                onProgress: onProgress
            )
        }
        CompressDiagnostics.log("compress finished successfully")
    }

    private static func verifyIntegritySynchronously(url: URL, password: String?) throws -> String {
        guard ArchiveFormatCatalog.isArchive(url) else {
            throw ArchiveError.unsupportedFormat
        }

        let noPassword = password == nil || password?.isEmpty == true
        let ext = ArchiveFormatCatalog.normalizedExtension(for: url)
        let isZip = ArchiveFormatCatalog.zipExtensions.contains(ext)
        let isDmg = ext == "dmg"

        if isDmg, ToolLocator.hdiutilPath != nil {
            return try DmgCompressBackend.verify(at: url, password: password)
        }

        if isZip && noPassword, let unzip = ToolLocator.unzipPath {
            let result = try ProcessRunner.run(executable: unzip, arguments: ["-t", url.path])
            if result.exitCode == 0 {
                let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                if message.localizedCaseInsensitiveContains("no errors detected") {
                    return "Integrity check passed."
                }
                return message.isEmpty ? "Integrity check passed." : message
            }
        }

        guard ToolLocator.isSevenZipAvailable else {
            throw ArchiveError.toolUnavailable("7-Zip")
        }
        return try SevenZipBackend.verify(at: url, password: password)
    }

    private static func listSynchronously(url: URL, password: String?) throws -> ArchiveListing {
        guard ArchiveFormatCatalog.isArchive(url) else {
            throw ArchiveError.unsupportedFormat
        }

        let archiveSize = fileSize(url)
        let format = ArchiveFormatCatalog.formatLabel(for: url)
        let backend = ArchiveFormatCatalog.preferredBackend(for: url)

        let entries: [ArchiveEntry]
        let note: String?

        switch backend {
        case .zipNative:
            do {
                entries = try ZipArchiveLister.entries(at: url, maxEntries: maxEntries)
                note = nil
            } catch ArchiveError.passwordRequired {
                guard let password, !password.isEmpty else { throw ArchiveError.passwordRequired }
                guard ToolLocator.isSevenZipAvailable else {
                    throw ArchiveError.toolUnavailable("7-Zip")
                }
                entries = try SevenZipBackend.list(at: url, maxEntries: maxEntries, password: password)
                note = "Listed via 7-Zip"
            } catch ArchiveError.zipRequiresSevenZip {
                guard ToolLocator.isSevenZipAvailable else {
                    throw ArchiveError.toolUnavailable("7-Zip")
                }
                entries = try SevenZipBackend.list(at: url, maxEntries: maxEntries, password: password)
                note = "Listed via 7-Zip"
            } catch ArchiveError.invalidArchive {
                throw ArchiveError.invalidArchive
            } catch let error as ArchiveError {
                throw error
            } catch {
                guard ToolLocator.isSevenZipAvailable else { throw error }
                entries = try SevenZipBackend.list(at: url, maxEntries: maxEntries, password: password)
                note = "Listed via 7-Zip"
            }
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                do {
                    entries = try TarBackend.list(at: url, maxEntries: maxEntries)
                    note = nil
                } catch {
                    guard ToolLocator.isSevenZipAvailable else { throw error }
                    entries = try SevenZipBackend.list(at: url, maxEntries: maxEntries, password: password)
                    note = "Listed via 7-Zip"
                }
            } else if ToolLocator.isSevenZipAvailable {
                entries = try SevenZipBackend.list(at: url, maxEntries: maxEntries, password: password)
                note = "Listed via 7-Zip"
            } else {
                throw ArchiveError.toolUnavailable("bsdtar or 7-Zip")
            }
        case .sevenZip:
            guard ToolLocator.isSevenZipAvailable else {
                throw ArchiveError.toolUnavailable("7-Zip")
            }
            entries = try SevenZipBackend.list(at: url, maxEntries: maxEntries, password: password)
            note = nil
        }

        let sorted = sortEntries(entries)
        let truncated = entries.count >= maxEntries
        let total = sorted.reduce(Int64(0)) { partial, entry in
            entry.isDirectory ? partial : partial + max(0, entry.uncompressedSize)
        }

        return ArchiveListing(
            format: format,
            entries: sorted,
            archiveURL: url,
            archiveSize: archiveSize,
            totalUncompressedSize: total,
            truncated: truncated,
            note: note
        )
    }

    private static func extractSynchronously(
        entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool,
        password: String?
    ) throws {
        guard !entries.isEmpty else { return }
        try PathSafety.validateEntries(entries)

        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        switch backend {
        case .zipNative:
            if ToolLocator.isSevenZipAvailable {
                try SevenZipBackend.extract(
                    entries: entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths,
                    password: password
                )
            } else {
                try extractZipEntries(entries, from: archive, to: destination, preservePaths: preservePaths)
            }
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                try TarBackend.extract(
                    entries: entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths
                )
            } else {
                try SevenZipBackend.extract(
                    entries: entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths,
                    password: password
                )
            }
        case .sevenZip:
            try SevenZipBackend.extract(
                entries: entries,
                from: archive,
                to: destination,
                preservePaths: preservePaths,
                password: password
            )
        }
    }

    private static func extractAllSynchronously(
        from archive: URL,
        to destination: URL,
        password: String?
    ) throws {
        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        switch backend {
        case .zipNative, .sevenZip:
            try SevenZipBackend.extractAll(from: archive, to: destination, password: password)
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                try TarBackend.extractAll(from: archive, to: destination)
            } else {
                try SevenZipBackend.extractAll(from: archive, to: destination, password: password)
            }
        }
    }

    private static func extractToTempSynchronously(
        entry: ArchiveEntry,
        from archive: URL,
        password: String?,
        catalogEntries: [ArchiveEntry]
    ) throws -> URL {
        if entry.isDirectory {
            return try extractFolderToTemp(
                entry: entry,
                from: archive,
                password: password,
                catalogEntries: catalogEntries
            )
        }

        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        switch backend {
        case .zipNative, .sevenZip:
            return try SevenZipBackend.extractToTemp(entry: entry, from: archive, password: password)
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                return try TarBackend.extractToTemp(entry: entry, from: archive)
            }
            return try SevenZipBackend.extractToTemp(entry: entry, from: archive, password: password)
        }
    }

    private static func extractFolderToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        password: String?,
        catalogEntries: [ArchiveEntry]
    ) throws -> URL {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        TempFileRegistry.registerExtractRoot(tempRoot)

        let folderPath = entry.normalizedPath
        let folderURL = try PathSafety.resolvedURL(
            forEntryPath: folderPath.hasSuffix("/") ? folderPath : folderPath + "/",
            in: tempRoot
        )

        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        switch backend {
        case .zipNative, .sevenZip:
            if ToolLocator.isSevenZipAvailable {
                try? SevenZipBackend.extractFolder(
                    entry: entry,
                    from: archive,
                    to: tempRoot,
                    password: password
                )
            }
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                try? TarBackend.extractFolder(entry: entry, from: archive, to: tempRoot)
            } else if ToolLocator.isSevenZipAvailable {
                try? SevenZipBackend.extractFolder(
                    entry: entry,
                    from: archive,
                    to: tempRoot,
                    password: password
                )
            }
        }

        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let prefix = folderPath + "/"
            let descendants = catalogEntries.filter {
                !$0.isDirectory && $0.normalizedPath.hasPrefix(prefix)
            }
            if !descendants.isEmpty {
                try extractSynchronously(
                    entries: descendants,
                    from: archive,
                    to: tempRoot,
                    preservePaths: true,
                    password: password
                )
            }
        }

        isDirectory = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return folderURL
        }

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            throw ArchiveError.entryNotFound(entry.path)
        }
        return folderURL
    }

    private static func extractZipEntries(
        _ entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool
    ) throws {
        guard let unzip = ToolLocator.unzipPath else {
            throw ArchiveError.toolUnavailable("unzip")
        }

        try PathSafety.validateEntries(entries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries where !entry.isDirectory {
            var arguments = ["-o", archive.path, entry.path, "-d", destination.path]
            if !preservePaths {
                arguments = ["-jo", archive.path, entry.path, "-d", destination.path]
            }
            let result = try ProcessRunner.run(executable: unzip, arguments: arguments)
            guard result.exitCode == 0 else {
                let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ArchiveError.commandFailed(message.isEmpty ? "unzip failed" : message)
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func sortEntries(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }
}