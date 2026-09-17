import Foundation

enum ArchiveEngine {
    static let maxEntries = 10_000

    static func list(
        url: URL,
        password: String? = nil,
        handle: ProcessRunner.Handle? = nil
    ) async throws -> ArchiveListing {
        try await Task.detached(priority: .userInitiated) {
            try listSynchronously(url: url, password: password, handle: handle)
        }.value
    }

    static func extract(
        entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool = true,
        password: String? = nil,
        handle: ProcessRunner.Handle? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try extractSynchronously(
                entries: entries,
                from: archive,
                to: destination,
                preservePaths: preservePaths,
                password: password,
                handle: handle
            )
        }.value
    }

    static func extractAll(
        from archive: URL,
        to destination: URL,
        password: String? = nil,
        handle: ProcessRunner.Handle? = nil
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try extractAllSynchronously(
                from: archive,
                to: destination,
                password: password,
                handle: handle
            )
        }.value
    }

    static func extractToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        password: String? = nil,
        catalogEntries: [ArchiveEntry] = [],
        handle: ProcessRunner.Handle? = nil
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try extractToTempSynchronously(
                entry: entry,
                from: archive,
                password: password,
                catalogEntries: catalogEntries,
                handle: handle
            )
        }.value
    }

    static func verifyIntegrity(
        url: URL,
        password: String? = nil,
        accessTokens: [SecurityScopedAccess.Token] = [],
        handle: ProcessRunner.Handle? = nil
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            _ = SecurityScopedAccess.activate(accessTokens)
            defer { SecurityScopedAccess.deactivate(accessTokens) }
            let archive = try resolvedArchiveFile(url)
            let volumes = SplitArchive.set(for: archive)?.volumes ?? [archive]
            try SecurityScopedAccess.validateReadable(volumes)
            return try verifyIntegritySynchronously(url: archive, password: password, handle: handle)
        }.value
    }

    static func compress(
        sources: [URL],
        to archive: URL,
        format: CompressFormat,
        compressionLevel: Int = 5,
        password: String? = nil,
        solidArchive: Bool = false,
        volumeArgument: String? = nil,
        dmgAppInstallerLayout: Bool = false,
        /// When true, integrity-test the staged archive **before** replacing any existing final file.
        verifyBeforeCommit: Bool = false,
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
                volumeArgument: volumeArgument,
                dmgAppInstallerLayout: dmgAppInstallerLayout,
                verifyBeforeCommit: verifyBeforeCommit,
                accessTokens: accessTokens,
                handle: handle,
                onProgress: onProgress
            )
        }.value
    }

    static func addToArchive(
        sources: [URL],
        archive: URL,
        archiveFolder: String,
        compressionLevel: Int = 5,
        password: String? = nil,
        accessTokens: [SecurityScopedAccess.Token] = [],
        handle: ProcessRunner.Handle? = nil,
        onProgress: @escaping @Sendable (CompressionProgressUpdate) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            _ = SecurityScopedAccess.activate(accessTokens)
            defer { SecurityScopedAccess.deactivate(accessTokens) }
            try SecurityScopedAccess.validateReadable([archive] + sources)
            guard ArchiveFormatCatalog.supportsMutation(archive) else {
                throw ArchiveError.cannotModifyArchive(
                    ArchiveFormatCatalog.mutationUnsupportedMessage(for: archive)
                )
            }
            guard FileManager.default.isWritableFile(atPath: archive.path) else {
                throw ArchiveError.permissionDenied(archive.lastPathComponent)
            }
            try SevenZipBackend.add(
                sources: sources,
                to: archive,
                archiveFolder: archiveFolder,
                compressionLevel: compressionLevel,
                password: password,
                handle: handle,
                onProgress: onProgress
            )
        }.value
    }

    static func removeFromArchive(
        entries: [ArchiveEntry],
        archive: URL,
        catalogEntries: [ArchiveEntry],
        truncatedListing: Bool,
        password: String? = nil,
        accessTokens: [SecurityScopedAccess.Token] = [],
        handle: ProcessRunner.Handle? = nil,
        onProgress: @escaping @Sendable (CompressionProgressUpdate) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            _ = SecurityScopedAccess.activate(accessTokens)
            defer { SecurityScopedAccess.deactivate(accessTokens) }
            try SecurityScopedAccess.validateReadable([archive])
            guard ArchiveFormatCatalog.supportsMutation(archive) else {
                throw ArchiveError.cannotModifyArchive(
                    ArchiveFormatCatalog.mutationUnsupportedMessage(for: archive)
                )
            }
            guard FileManager.default.isWritableFile(atPath: archive.path) else {
                throw ArchiveError.permissionDenied(archive.lastPathComponent)
            }

            let expanded = expandEntriesForRemoval(entries, catalog: catalogEntries)
            guard !expanded.isEmpty else {
                throw ArchiveError.invalidSelection
            }
            if truncatedListing, entries.contains(where: \.isDirectory) {
                throw ArchiveError.cannotModifyArchive(
                    "This archive listing is truncated, so folders cannot be removed safely. Remove individual files, or extract and create a new archive."
                )
            }
            try PathSafety.validateEntries(expanded)
            var deletePaths: [String] = []
            for entry in expanded {
                deletePaths.append(entry.normalizedPath)
                if entry.isDirectory {
                    deletePaths.append(entry.normalizedPath + "/")
                } else {
                    deletePaths.append(entry.path)
                }
            }
            try SevenZipBackend.delete(
                paths: deletePaths,
                from: archive,
                password: password,
                handle: handle,
                onProgress: onProgress
            )
        }.value
    }

    private static func expandEntriesForRemoval(
        _ entries: [ArchiveEntry],
        catalog: [ArchiveEntry]
    ) -> [ArchiveEntry] {
        var seen = Set<String>()
        var result: [ArchiveEntry] = []

        func include(_ entry: ArchiveEntry) {
            let key = entry.normalizedPath.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }

        for entry in entries {
            include(entry)
            guard entry.isDirectory else { continue }
            let prefix = entry.normalizedPath
            let childPrefix = prefix + "/"
            for candidate in catalog {
                let path = candidate.normalizedPath
                if path == prefix || path.hasPrefix(childPrefix) {
                    include(candidate)
                }
            }
        }
        return result
    }

    private static func performCompress(
        sources: [URL],
        to archive: URL,
        format: CompressFormat,
        compressionLevel: Int,
        password: String?,
        solidArchive: Bool,
        volumeArgument: String?,
        dmgAppInstallerLayout: Bool,
        verifyBeforeCommit: Bool,
        accessTokens: [SecurityScopedAccess.Token],
        handle: ProcessRunner.Handle?,
        onProgress: @escaping @Sendable (CompressionProgressUpdate) -> Void
    ) throws {
        // Activate when tokens carry a real security scope; do not hard-fail when
        // startAccessing returns false (common for non-scoped / non-sandboxed paths).
        _ = SecurityScopedAccess.activate(accessTokens)
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

        let beforeCommit: ((URL) throws -> Void)?
        if verifyBeforeCommit {
            beforeCommit = { stagedURL in
                if handle?.wasCancelled == true { throw ArchiveError.cancelled }
                onProgress(CompressionProgressUpdate(
                    fraction: 0.99,
                    message: "Verifying integrity…",
                    indeterminate: true
                ))
                CompressDiagnostics.log("verify-before-commit: \(stagedURL.path)")
                _ = try verifyIntegritySynchronously(
                    url: stagedURL,
                    password: password,
                    handle: handle
                )
                CompressDiagnostics.log("verify-before-commit: ok")
            }
        } else {
            beforeCommit = nil
        }

        let splitting = volumeArgument != nil
        let noPassword = password == nil || password?.isEmpty == true
        let useDitto = format == .zip
            && noPassword
            && !splitting
            && workSources.count == 1
            && ToolLocator.dittoPath != nil
        let useNativeZip = format == .zip
            && noPassword
            && !splitting
            && ToolLocator.zipPath != nil
        let useNativeTar = format.isTarFamily
            && noPassword
            && ToolLocator.bsdtarPath != nil
        let useDmg = format.isDmg && ToolLocator.hdiutilPath != nil

        if format.isRar {
            try RarCompressBackend.compress(
                sources: workSources,
                to: archive,
                compressionLevel: compressionLevel,
                password: password,
                solidArchive: solidArchive,
                volumeArgument: volumeArgument,
                handle: handle,
                beforeCommit: beforeCommit,
                onProgress: onProgress
            )
        } else if useDmg {
            try DmgCompressBackend.compress(
                sources: workSources,
                to: archive,
                compressionLevel: compressionLevel,
                password: password,
                appInstallerLayout: dmgAppInstallerLayout,
                handle: handle,
                beforeCommit: beforeCommit,
                onProgress: onProgress
            )
        } else if useDitto {
            try DittoCompressBackend.compress(
                sources: workSources,
                to: archive,
                handle: handle,
                beforeCommit: beforeCommit,
                onProgress: onProgress
            )
        } else if useNativeZip {
            try ZipCompressBackend.compress(
                sources: workSources,
                to: archive,
                compressionLevel: compressionLevel,
                handle: handle,
                beforeCommit: beforeCommit,
                onProgress: onProgress
            )
        } else if useNativeTar {
            try TarCompressBackend.compress(
                sources: workSources,
                to: archive,
                format: format,
                handle: handle,
                beforeCommit: beforeCommit,
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
                volumeArgument: volumeArgument,
                handle: handle,
                beforeCommit: beforeCommit,
                onProgress: onProgress
            )
        }
        CompressDiagnostics.log("compress finished successfully")
    }

    private static func resolvedArchiveFile(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let canonical = ArchiveFormatCatalog.canonicalArchiveURL(for: standardized)
        if canonical.path.compare(standardized.path, options: [.caseInsensitive, .literal]) != .orderedSame,
           !FileManager.default.fileExists(atPath: canonical.path) {
            throw ArchiveError.splitFirstVolumeMissing(canonical.lastPathComponent)
        }
        return canonical
    }

    private static func archiveByteSize(_ url: URL) -> Int64 {
        if let split = SplitArchive.set(for: url), !split.volumes.isEmpty {
            return split.volumes.reduce(Int64(0)) { $0 + fileSize($1) }
        }
        return fileSize(url)
    }

    private static func verifyIntegritySynchronously(
        url: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws -> String {
        let archive = try resolvedArchiveFile(url)
        guard ArchiveFormatCatalog.isArchive(archive) else {
            throw ArchiveError.unsupportedFormat
        }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        if SplitArchive.set(for: archive) != nil {
            guard ToolLocator.isSevenZipAvailable else {
                throw ArchiveError.toolUnavailable("7-Zip")
            }
            return try SevenZipBackend.verify(at: archive, password: password, handle: handle)
        }

        let noPassword = password == nil || password?.isEmpty == true
        let ext = ArchiveFormatCatalog.normalizedExtension(for: archive)
        let isZip = ArchiveFormatCatalog.zipExtensions.contains(ext)
        let isDmg = ext == "dmg"

        if isDmg, ToolLocator.hdiutilPath != nil {
            return try DmgCompressBackend.verify(at: archive, password: password, handle: handle)
        }

        if isZip && noPassword, let unzip = ToolLocator.unzipPath {
            let result = try ProcessRunner.run(
                executable: unzip,
                arguments: ["-t", archive.path],
                handle: handle
            )
            if result.wasCancelled { throw ArchiveError.cancelled }
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
        return try SevenZipBackend.verify(at: archive, password: password, handle: handle)
    }

    private static func listSynchronously(
        url: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws -> ArchiveListing {
        let archive = try resolvedArchiveFile(url)
        guard ArchiveFormatCatalog.isArchive(archive) else {
            throw ArchiveError.unsupportedFormat
        }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let archiveSize = archiveByteSize(archive)
        let format = ArchiveFormatCatalog.formatLabel(for: archive)
        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)

        // Ask for one extra entry so "exactly maxEntries" is not falsely treated as truncated.
        let listLimit = maxEntries + 1
        var entries: [ArchiveEntry]
        let note: String?

        switch backend {
        case .zipNative:
            do {
                entries = try ZipArchiveLister.entries(at: archive, maxEntries: listLimit)
                note = nil
            } catch ArchiveError.passwordRequired {
                guard let password, !password.isEmpty else { throw ArchiveError.passwordRequired }
                guard ToolLocator.isSevenZipAvailable else {
                    throw ArchiveError.toolUnavailable("7-Zip")
                }
                entries = try SevenZipBackend.list(
                    at: archive,
                    maxEntries: listLimit,
                    password: password,
                    handle: handle
                )
                note = "Listed via 7-Zip"
            } catch ArchiveError.zipRequiresSevenZip {
                guard ToolLocator.isSevenZipAvailable else {
                    throw ArchiveError.toolUnavailable("7-Zip")
                }
                entries = try SevenZipBackend.list(
                    at: archive,
                    maxEntries: listLimit,
                    password: password,
                    handle: handle
                )
                note = "Listed via 7-Zip"
            } catch ArchiveError.invalidArchive {
                throw ArchiveError.invalidArchive
            } catch let error as ArchiveError {
                throw error
            } catch {
                guard ToolLocator.isSevenZipAvailable else { throw error }
                entries = try SevenZipBackend.list(
                    at: archive,
                    maxEntries: listLimit,
                    password: password,
                    handle: handle
                )
                note = "Listed via 7-Zip"
            }
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                do {
                    entries = try TarBackend.list(at: archive, maxEntries: listLimit, handle: handle)
                    note = nil
                } catch {
                    guard ToolLocator.isSevenZipAvailable else { throw error }
                    entries = try SevenZipBackend.list(
                        at: archive,
                        maxEntries: listLimit,
                        password: password,
                        handle: handle
                    )
                    note = "Listed via 7-Zip"
                }
            } else if ToolLocator.isSevenZipAvailable {
                entries = try SevenZipBackend.list(
                    at: archive,
                    maxEntries: listLimit,
                    password: password,
                    handle: handle
                )
                note = "Listed via 7-Zip"
            } else {
                throw ArchiveError.toolUnavailable("bsdtar or 7-Zip")
            }
        case .sevenZip:
            guard ToolLocator.isSevenZipAvailable else {
                throw ArchiveError.toolUnavailable("7-Zip")
            }
            entries = try SevenZipBackend.list(
                at: archive,
                maxEntries: listLimit,
                password: password,
                handle: handle
            )
            note = nil
        }

        let truncated = entries.count > maxEntries
        if truncated {
            entries = Array(entries.prefix(maxEntries))
        }

        let sorted = sortEntries(entries)
        let total = sorted.reduce(Int64(0)) { partial, entry in
            entry.isDirectory ? partial : partial + max(0, entry.uncompressedSize)
        }

        var listingNote = note
        if let volumeNote = SplitArchive.set(for: archive)?.volumeNote {
            if let existing = listingNote, !existing.isEmpty {
                listingNote = "\(existing) · \(volumeNote)"
            } else {
                listingNote = volumeNote
            }
        }

        return ArchiveListing(
            format: format,
            entries: sorted,
            archiveURL: archive,
            archiveSize: archiveSize,
            totalUncompressedSize: total,
            truncated: truncated,
            note: listingNote
        )
    }

    private static func extractSynchronously(
        entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard !entries.isEmpty else { return }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        try PathSafety.validateEntries(entries)
        let archive = try resolvedArchiveFile(archive)

        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        switch backend {
        case .zipNative:
            if ToolLocator.isSevenZipAvailable {
                try SevenZipBackend.extract(
                    entries: entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths,
                    password: password,
                    handle: handle
                )
            } else {
                try extractZipEntries(
                    entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths,
                    handle: handle
                )
            }
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                try TarBackend.extract(
                    entries: entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths,
                    handle: handle
                )
            } else {
                try SevenZipBackend.extract(
                    entries: entries,
                    from: archive,
                    to: destination,
                    preservePaths: preservePaths,
                    password: password,
                    handle: handle
                )
            }
        case .sevenZip:
            try SevenZipBackend.extract(
                entries: entries,
                from: archive,
                to: destination,
                preservePaths: preservePaths,
                password: password,
                handle: handle
            )
        }
        try PathSafety.enforceExtractContainment(in: destination)
    }

    private static func extractAllSynchronously(
        from archive: URL,
        to destination: URL,
        password: String?,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        // Apply the same zip-slip checks as selected extract: list first, validate every path,
        // then hand the archive to the tool. Refuse if the listing was truncated so we cannot
        // vouch for every entry.
        let listing = try listSynchronously(url: archive, password: password, handle: handle)
        try PathSafety.validateEntries(listing.entries)
        if listing.truncated {
            throw ArchiveError.commandFailed(
                "This archive has too many entries to validate before Extract All (limit \(maxEntries)). Extract selected items instead, or split the archive."
            )
        }
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }

        let source = listing.archiveURL
        let backend = ArchiveFormatCatalog.preferredBackend(for: source)
        switch backend {
        case .zipNative:
            if ToolLocator.isSevenZipAvailable {
                try SevenZipBackend.extractAll(
                    from: source,
                    to: destination,
                    password: password,
                    handle: handle
                )
            } else {
                try extractZipAll(from: source, to: destination, handle: handle)
            }
        case .sevenZip:
            try SevenZipBackend.extractAll(
                from: source,
                to: destination,
                password: password,
                handle: handle
            )
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                try TarBackend.extractAll(from: source, to: destination, handle: handle)
            } else {
                try SevenZipBackend.extractAll(
                    from: source,
                    to: destination,
                    password: password,
                    handle: handle
                )
            }
        }
        try PathSafety.enforceExtractContainment(in: destination)
    }

    /// Fallback Extract All for ZIP when 7-Zip is unavailable (paths already validated).
    private static func extractZipAll(
        from archive: URL,
        to destination: URL,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let unzip = ToolLocator.unzipPath else {
            throw ArchiveError.toolUnavailable("unzip")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try ProcessRunner.run(
            executable: unzip,
            arguments: ["-o", archive.path, "-d", destination.path],
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.commandFailed(message.isEmpty ? "unzip failed" : message)
        }
    }

    private static func extractToTempSynchronously(
        entry: ArchiveEntry,
        from archive: URL,
        password: String?,
        catalogEntries: [ArchiveEntry],
        handle: ProcessRunner.Handle? = nil
    ) throws -> URL {
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        let archive = try resolvedArchiveFile(archive)
        if entry.isDirectory {
            return try extractFolderToTemp(
                entry: entry,
                from: archive,
                password: password,
                catalogEntries: catalogEntries,
                handle: handle
            )
        }

        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        switch backend {
        case .zipNative:
            if ToolLocator.isSevenZipAvailable {
                return try SevenZipBackend.extractToTemp(
                    entry: entry,
                    from: archive,
                    password: password,
                    handle: handle
                )
            }
            return try extractZipEntryToTemp(entry: entry, from: archive, handle: handle)
        case .sevenZip:
            return try SevenZipBackend.extractToTemp(
                entry: entry,
                from: archive,
                password: password,
                handle: handle
            )
        case .tar:
            if ToolLocator.bsdtarPath != nil {
                return try TarBackend.extractToTemp(entry: entry, from: archive, handle: handle)
            }
            return try SevenZipBackend.extractToTemp(
                entry: entry,
                from: archive,
                password: password,
                handle: handle
            )
        }
    }

    /// Extract a single ZIP member without 7-Zip (open / Quick Look / drag-out fallback).
    private static func extractZipEntryToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        handle: ProcessRunner.Handle? = nil
    ) throws -> URL {
        try PathSafety.validateArchiveEntryPath(entry.path)
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        TempFileRegistry.registerExtractRoot(tempRoot)
        try extractZipEntries([entry], from: archive, to: tempRoot, preservePaths: true, handle: handle)
        let extracted = try PathSafety.resolvedURL(forEntryPath: entry.normalizedPath, in: tempRoot)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw ArchiveError.entryNotFound(entry.path)
        }
        return extracted
    }

    private static func extractFolderToTemp(
        entry: ArchiveEntry,
        from archive: URL,
        password: String?,
        catalogEntries: [ArchiveEntry],
        handle: ProcessRunner.Handle? = nil
    ) throws -> URL {
        if handle?.wasCancelled == true { throw ArchiveError.cancelled }
        try PathSafety.validateArchiveEntryPath(entry.path)

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        TempFileRegistry.registerExtractRoot(tempRoot)

        let folderPath = entry.normalizedPath
        let folderURL = try PathSafety.resolvedURL(
            forEntryPath: folderPath.hasSuffix("/") ? String(folderPath.dropLast()) : folderPath,
            in: tempRoot
        )

        let descendants = catalogEntries.filter {
            !$0.isDirectory && pathIsUnderFolder($0.normalizedPath, folder: folderPath)
        }

        let backend = ArchiveFormatCatalog.preferredBackend(for: archive)
        var toolError: Error?

        do {
            switch backend {
            case .zipNative:
                if ToolLocator.isSevenZipAvailable {
                    try SevenZipBackend.extractFolder(
                        entry: entry,
                        from: archive,
                        to: tempRoot,
                        password: password,
                        handle: handle
                    )
                } else if !descendants.isEmpty {
                    try extractZipEntries(
                        descendants,
                        from: archive,
                        to: tempRoot,
                        preservePaths: true,
                        handle: handle
                    )
                } else if ToolLocator.unzipPath != nil {
                    try extractZipFolder(entry: entry, from: archive, to: tempRoot, handle: handle)
                } else {
                    throw ArchiveError.toolUnavailable("unzip")
                }
            case .sevenZip:
                try SevenZipBackend.extractFolder(
                    entry: entry,
                    from: archive,
                    to: tempRoot,
                    password: password,
                    handle: handle
                )
            case .tar:
                if ToolLocator.bsdtarPath != nil {
                    try TarBackend.extractFolder(entry: entry, from: archive, to: tempRoot, handle: handle)
                } else {
                    try SevenZipBackend.extractFolder(
                        entry: entry,
                        from: archive,
                        to: tempRoot,
                        password: password,
                        handle: handle
                    )
                }
            }
        } catch {
            toolError = error
        }

        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            // Tool path missed the folder (or failed): fall back to catalog file extract.
            if !descendants.isEmpty {
                try extractSynchronously(
                    entries: descendants,
                    from: archive,
                    to: tempRoot,
                    preservePaths: true,
                    password: password,
                    handle: handle
                )
                toolError = nil
            }
        }

        isDirectory = false
        if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return folderURL
        }

        // Genuinely empty folder in the archive — create it. Never mask extract failures.
        if descendants.isEmpty, toolError == nil {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: folderURL.path) else {
                throw ArchiveError.entryNotFound(entry.path)
            }
            return folderURL
        }

        if let toolError {
            throw toolError
        }
        throw ArchiveError.entryNotFound(entry.path)
    }

    /// True when `path` is the folder itself or a strict descendant (`folder/…`).
    private static func pathIsUnderFolder(_ path: String, folder: String) -> Bool {
        if folder.isEmpty { return true }
        if path == folder { return true }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    private static func extractZipFolder(
        entry: ArchiveEntry,
        from archive: URL,
        to destination: URL,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let unzip = ToolLocator.unzipPath else {
            throw ArchiveError.toolUnavailable("unzip")
        }
        try PathSafety.validateArchiveEntryPath(entry.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let prefix = entry.normalizedPath
        let result = try ProcessRunner.run(
            executable: unzip,
            arguments: ["-o", archive.path, "\(prefix)/*", "-d", destination.path],
            handle: handle
        )
        if result.wasCancelled { throw ArchiveError.cancelled }
        guard result.exitCode == 0 else {
            let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty folders often make unzip exit non-zero when the glob matches nothing.
            if message.localizedCaseInsensitiveContains("caution")
                || message.localizedCaseInsensitiveContains("filename not matched") {
                return
            }
            throw ArchiveError.commandFailed(message.isEmpty ? "unzip folder extraction failed" : message)
        }
    }

    private static func extractZipEntries(
        _ entries: [ArchiveEntry],
        from archive: URL,
        to destination: URL,
        preservePaths: Bool,
        handle: ProcessRunner.Handle? = nil
    ) throws {
        guard let unzip = ToolLocator.unzipPath else {
            throw ArchiveError.toolUnavailable("unzip")
        }

        try PathSafety.validateEntries(entries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries where !entry.isDirectory {
            if handle?.wasCancelled == true { throw ArchiveError.cancelled }
            var arguments = ["-o", archive.path, entry.path, "-d", destination.path]
            if !preservePaths {
                arguments = ["-jo", archive.path, entry.path, "-d", destination.path]
            }
            let result = try ProcessRunner.run(executable: unzip, arguments: arguments, handle: handle)
            if result.wasCancelled { throw ArchiveError.cancelled }
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