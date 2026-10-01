import Foundation

enum CompressionSupport {
    static func isApplicationBundle(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func applicationBundles(in sources: [URL], fileManager: FileManager = .default) -> [URL] {
        sources.filter { isApplicationBundle($0, fileManager: fileManager) }
    }

    struct Context: Sendable {
        let workingDirectory: URL
        let itemNames: [String]
    }

    struct CompressionDestination: Sendable {
        let workURL: URL
        let finalURL: URL
        let shouldRelocate: Bool
    }

    struct StagedCompressSources {
        let urls: [URL]
        let cleanup: () -> Void
    }

    static func compressStatusMessage(for sources: [URL], fileManager: FileManager = .default) -> String {
        if sourcesIncludeDirectory(sources, fileManager: fileManager) {
            return "Compressing folder… Large folders may take several minutes."
        }
        let bytes = totalSourceBytes(sources, fileManager: fileManager)
        guard bytes > 0 else { return "Compressing…" }
        let label = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if bytes > 50_000_000 {
            return "Compressing \(label)… This may take several minutes."
        }
        return "Compressing \(label)…"
    }

    static func formattedSourceSize(_ sources: [URL], fileManager: FileManager = .default) -> String {
        let bytes = totalSourceBytes(sources, fileManager: fileManager)
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func totalSourceBytes(_ sources: [URL], fileManager: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        for source in sources {
            total += byteCount(at: source, fileManager: fileManager)
        }
        return total
    }

    private static func byteCount(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }

        // Include hidden project trees (.git, .build, etc.) so status size matches what we archive.
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Copy sources into temp before compression. Keeps project trees complete (`.git`,
    /// `.gitignore`, `.build`, `node_modules`, hidden config, symlinks, packages) unless a
    /// pattern in Settings → Exclusions says otherwise. Always strips macOS junk
    /// (`.DS_Store`, AppleDouble `._*`, `__MACOSX`). Runs in-process with security scope.
    ///
    /// Uses whole-tree `copyItem` (not file-by-file walk) so large SwiftPM `.build` trees,
    /// `.app` bundles, and framework layouts stay intact and prepare does not hang on symlink
    /// target resolution mid-walk.
    ///
    /// - Parameter isCancelled: polled **between** top-level items so Cancel during prepare
    ///   aborts before the next item / compressor starts. A single whole-tree `copyItem` of a
    ///   huge folder is not interruptible mid-copy (by design — whole-tree copy avoids hangs
    ///   and incompleteness from file-by-file walks); Cancel is observed when that copy returns.
    static func stageForSevenZip(
        _ sources: [URL],
        onProgress: ((CompressionProgressUpdate) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
        fileManager: FileManager = .default
    ) throws -> StagedCompressSources {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        let exclusions = ArchiveExclusions.Matcher(patterns: AppSettings.customExclusionPatterns)
        try validateUniqueStagingBasenames(standardized, exclusions: exclusions)

        if isCancelled?() == true { throw ArchiveError.cancelled }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ArchivePeek-input-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var stagedItems = 0
        for (index, source) in standardized.enumerated() {
            if isCancelled?() == true {
                try? fileManager.removeItem(at: stagingRoot)
                throw ArchiveError.cancelled
            }

            var isDirectory: ObjCBool = false
            // fileExists follows symlinks for the isDirectory check; also accept plain symlinks.
            let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
                || ((try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
            guard exists else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }

            if shouldOmitFromArchive(source.lastPathComponent, exclusions: exclusions) { continue }

            let destination = stagingRoot.appendingPathComponent(source.lastPathComponent)
            let isSymlink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let label = source.lastPathComponent
            // Avoid size walks here: they re-enumerate huge trees and can resolve symlink targets.
            onProgress?(CompressionProgressUpdate(
                fraction: 0,
                message: "Preparing \(label)… \(index + 1)/\(standardized.count)",
                indeterminate: true
            ))
            CompressDiagnostics.log("staging copy: \(source.path) → \(destination.path)")

            if isSymlink {
                // Link text only — never open the target (hangs on dead mounts / loops).
                try copySymlinkWithoutResolving(from: source, to: destination, fileManager: fileManager)
            } else {
                // Whole-tree copy preserves packages, symlinks, empty dirs, and hidden project files.
                try copyCompressItem(from: source, to: destination, fileManager: fileManager)
                if isDirectory.boolValue {
                    try pruneStagedTree(destination, exclusions: exclusions, fileManager: fileManager)
                }
            }
            stagedItems += 1
            CompressDiagnostics.log("staging finished item: \(label)")
        }

        if isCancelled?() == true {
            try? fileManager.removeItem(at: stagingRoot)
            throw ArchiveError.cancelled
        }

        // Include hidden top-level items (e.g. `.git`, `.gitignore`).
        let allStagedURLs = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard !allStagedURLs.isEmpty else {
            throw ArchiveError.commandFailed("Nothing to compress after preparing files.")
        }

        // Log item count only — do not re-walk staged trees for file totals.
        CompressDiagnostics.log("staged \(stagedItems) top-level item(s) under \(stagingRoot.path)")

        return StagedCompressSources(
            urls: allStagedURLs.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            },
            cleanup: {
                try? fileManager.removeItem(at: stagingRoot)
            }
        )
    }

    /// Staging uses `lastPathComponent` only; two sources with the same basename would overwrite.
    /// Comparison is case-insensitive: the default APFS/HFS+ volume (and temp dir) is usually
    /// case-insensitive, so `Foo` and `foo` collide even though Swift String equality does not.
    static func validateUniqueStagingBasenames(
        _ sources: [URL],
        exclusions: ArchiveExclusions.Matcher? = nil
    ) throws {
        let matcher = exclusions ?? ArchiveExclusions.Matcher(patterns: AppSettings.customExclusionPatterns)
        var seen: [String: String] = [:] // lowercased key → display name
        var duplicates = Set<String>()
        for source in sources {
            let name = source.lastPathComponent
            if shouldOmitFromArchive(name, exclusions: matcher) { continue }
            let key = name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if let existing = seen[key] {
                duplicates.insert(existing)
                duplicates.insert(name)
            } else {
                seen[key] = name
            }
        }
        if !duplicates.isEmpty {
            throw ArchiveError.duplicateSourceNames(duplicates.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            })
        }
    }

    /// Remove macOS junk and Settings exclusions from an already-copied tree.
    /// Uses `subpathsOfDirectory` rather than `enumerator`: NSDirectoryEnumerator often omits
    /// AppleDouble `._*` files even when they exist as real names on disk.
    static func pruneStagedTree(
        _ root: URL,
        exclusions: ArchiveExclusions.Matcher? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: root.path) else { return }
        let matcher = exclusions ?? ArchiveExclusions.Matcher(patterns: AppSettings.customExclusionPatterns)

        var relativeDeletes: [String] = []
        // Subpaths are relative to the copied folder. The archive member path includes that folder's name,
        // so `src/*.swift` must also be tested as `src/` + the subpath when the copied folder is `src`.
        let rootName = root.lastPathComponent
        for sub in subpaths {
            let name = (sub as NSString).lastPathComponent
            let excluded = matcher.excludes(sub) || matcher.excludes(rootName + "/" + sub)
            guard isMacJunkFileName(name) || excluded else { continue }
            if relativeDeletes.contains(where: { sub.hasPrefix($0 + "/") }) { continue }
            relativeDeletes.removeAll { $0.hasPrefix(sub + "/") }
            relativeDeletes.append(sub)
        }
        // Deepest paths first so a nested match is removed before its parent.
        for relative in relativeDeletes.sorted(by: { $0.count > $1.count }) {
            try? fileManager.removeItem(at: root.appendingPathComponent(relative))
        }
    }

    /// Create a symlink at `destination` with the same link text as `source`.
    /// Uses `destinationOfSymbolicLink` only — never opens or stats the target, so broken
    /// mounts and circular links cannot hang prepare.
    private static func copySymlinkWithoutResolving(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let linkText = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        // removeItem works for files, dirs, and dangling symlinks (fileExists misses dangling links).
        try? fileManager.removeItem(at: destination)
        try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: linkText)
    }

    /// macOS junk, or a name selected by Settings → Exclusions.
    static func shouldOmitFromArchive(
        _ name: String,
        exclusions: ArchiveExclusions.Matcher? = nil
    ) -> Bool {
        if isMacJunkFileName(name) { return true }
        let matcher = exclusions ?? ArchiveExclusions.Matcher(patterns: AppSettings.customExclusionPatterns)
        return matcher.excludes(name)
    }

    /// Only true macOS archive noise — never project source such as `.gitignore` or `.git`.
    private static func isMacJunkFileName(_ name: String) -> Bool {
        if name == ".DS_Store" || name == "__MACOSX" { return true }
        if name.hasPrefix("._") { return true }
        return false
    }

    static func context(for sources: [URL], fileManager: FileManager = .default) throws -> Context {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        for source in standardized {
            guard sourceExists(source, fileManager: fileManager) else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }
        }

        let commonDirectory = commonParentDirectory(for: standardized) ?? standardized[0].deletingLastPathComponent()
        let itemNames = standardized.map { relativePath(for: $0, from: commonDirectory) }

        return Context(workingDirectory: commonDirectory, itemNames: itemNames)
    }

    /// `fileExists` follows links and returns false for a dangling symlink.
    /// Staging still copies that link text, so compress must accept it.
    private static func sourceExists(_ url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Relative item names with cwd at the nearest common parent — how macOS zip expects paths.
    static func zipContext(for sources: [URL], fileManager: FileManager = .default) throws -> Context {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        for source in standardized {
            guard sourceExists(source, fileManager: fileManager) else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }
        }

        let workingDirectory = commonParentDirectory(for: standardized)
            ?? standardized[0].deletingLastPathComponent()
        let itemNames = standardized.map { relativePath(for: $0, from: workingDirectory) }

        return Context(workingDirectory: workingDirectory, itemNames: itemNames)
    }

    /// Relative item names with cwd at the nearest common parent — for 7-Zip after staging.
    /// Absolute paths would be stored inside the archive as rooted temp paths; use relatives only.
    static func compressionInvocation(
        for sources: [URL],
        archive: URL,
        fileManager: FileManager = .default
    ) throws -> Context {
        // Same layout as zip: cwd = common parent (staging root), names = basenames / relatives.
        // `archive` is only validated for existence of a parent dir when creating the work file.
        _ = archive
        return try zipContext(for: sources, fileManager: fileManager)
    }

    static func normalizedArchiveURL(
        _ url: URL,
        format: CompressFormat,
        comicBookZip: Bool = false
    ) -> URL {
        let standardized = url.standardizedFileURL
        if hasExpectedExtension(standardized, format: format, comicBookZip: comicBookZip) {
            return standardized
        }

        let ext = format.outputExtension(comicBookZip: comicBookZip)
        if standardized.pathExtension.isEmpty {
            return URL(fileURLWithPath: standardized.path + "." + ext)
        }

        // Multi-part extensions (tar.gz) need path + suffix; single-part use appendingPathExtension.
        if ext.contains(".") {
            let name = standardized.deletingPathExtension().lastPathComponent
            return standardized
                .deletingLastPathComponent()
                .appendingPathComponent("\(name).\(ext)")
        }

        return standardized
            .deletingPathExtension()
            .appendingPathExtension(ext)
    }

    static func existingArchiveOutput(
        intended: URL,
        format: CompressFormat,
        comicBookZip: Bool = false,
        fileManager: FileManager = .default
    ) -> URL? {
        if fileManager.fileExists(atPath: intended.path) {
            return intended
        }

        if intended.pathExtension.isEmpty {
            let ext = format.outputExtension(comicBookZip: comicBookZip)
            let autoAdded = URL(fileURLWithPath: intended.path + "." + ext)
            if fileManager.fileExists(atPath: autoAdded.path) {
                return autoAdded
            }
        }

        return nil
    }

    static func hasExpectedExtension(
        _ url: URL,
        format: CompressFormat,
        comicBookZip: Bool = false
    ) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let expected = format.outputExtension(comicBookZip: comicBookZip).lowercased()
        if expected.contains(".") {
            return name.hasSuffix(".\(expected)")
        }
        return url.pathExtension.lowercased() == expected
    }

    static func proposedArchiveName(
        for sources: [URL],
        format: CompressFormat,
        comicBookZip: Bool = false
    ) -> String {
        let baseName: String
        if sources.count == 1 {
            let source = sources[0]
            if isApplicationBundle(source) {
                baseName = source.deletingPathExtension().lastPathComponent
            } else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    baseName = source.lastPathComponent
                } else {
                    baseName = source.deletingPathExtension().lastPathComponent
                }
            }
        } else {
            baseName = "Archive"
        }
        return "\(baseName).\(format.outputExtension(comicBookZip: comicBookZip))"
    }

    static func uniqueArchiveURL(
        proposedName: String,
        in directory: URL,
        format: CompressFormat? = nil,
        comicBookZip: Bool = false,
        fileManager: FileManager = .default
    ) -> URL {
        let initial = directory.appendingPathComponent(proposedName)
        guard fileManager.fileExists(atPath: initial.path) else { return initial }

        let fullExt = format?.outputExtension(comicBookZip: comicBookZip) ?? ""
        let base: String
        let suffix: String
        if !fullExt.isEmpty, proposedName.lowercased().hasSuffix("." + fullExt) {
            base = String(proposedName.dropLast(fullExt.count + 1))
            suffix = "." + fullExt
        } else {
            base = (proposedName as NSString).deletingPathExtension
            let ext = (proposedName as NSString).pathExtension
            suffix = ext.isEmpty ? "" : ".\(ext)"
        }

        for index in 2...999 {
            let candidate = directory.appendingPathComponent("\(base) \(index)\(suffix)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6))\(suffix)")
    }

    /// Always build in a unique temp file; replace the final path only after success.
    ///
    /// This is a fundamental ArchivePeek rule for every format (ZIP, 7z, TAR, DMG, ditto):
    /// if the user is overwriting `Backup.zip` and compression fails, the existing archive
    /// must remain untouched. Writing directly to the final path would risk truncating it
    /// mid-run and would force error cleanup to decide whether the final file is “ours.”
    static func compressionDestination(
        archive: URL,
        sources: [URL],
        format: CompressFormat,
        comicBookZip: Bool = false,
        fileManager: FileManager = .default
    ) -> CompressionDestination {
        _ = sources // retained for call-site symmetry / future nested-archive checks
        return temporaryCompressionDestination(
            archive: archive,
            format: format,
            comicBookZip: comicBookZip,
            fileManager: fileManager
        )
    }

    /// Build in a temp file first, then move into place with app security scope
    /// (child tools often cannot write to TCC-protected final folders).
    static func temporaryCompressionDestination(
        archive: URL,
        format: CompressFormat,
        comicBookZip: Bool = false,
        fileManager: FileManager = .default
    ) -> CompressionDestination {
        let finalURL = archive.standardizedFileURL
        // Prefer the format’s full extension (e.g. tar.gz / cbz) over URL.pathExtension alone.
        let formatExt = format.outputExtension(comicBookZip: comicBookZip)
        let ext: String
        if hasExpectedExtension(finalURL, format: format, comicBookZip: comicBookZip) {
            let name = finalURL.lastPathComponent
            if formatExt.contains("."), name.lowercased().hasSuffix("." + formatExt.lowercased()) {
                ext = formatExt
            } else if !finalURL.pathExtension.isEmpty {
                ext = finalURL.pathExtension
            } else {
                ext = formatExt
            }
        } else if finalURL.pathExtension.isEmpty {
            ext = formatExt
        } else {
            // Prefer the destination’s extension when it’s a ZIP alias (e.g. .cbz) so the
            // work/sibling file matches what we commit; otherwise fall back to format extension.
            let destExt = finalURL.pathExtension.lowercased()
            if format.isZip && ArchiveFormatCatalog.zipExtensions.contains(destExt) {
                ext = destExt
            } else {
                ext = formatExt
            }
        }
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString).\(ext)")
        return CompressionDestination(workURL: temp, finalURL: finalURL, shouldRelocate: true)
    }

    /// Commit a finished work archive to `finalURL` without risking the previous final file.
    ///
    /// Steps:
    /// 1. Copy/move the system-temp work file to a unique **sibling** of the final path
    ///    (`.ArchivePeek-<uuid>.partial` in the destination directory). `finalURL` is not touched.
    /// 2. Optionally run `beforeCommit` on that sibling (e.g. integrity verify).
    /// 3. Atomically replace `finalURL` with the sibling (`replaceItemAt` when a file already
    ///    exists; plain move when creating a new name).
    ///
    /// If any step fails, only work/partial temps are cleaned; an existing final archive remains.
    ///
    /// - Parameter beforeCommit: Optional gate (verify) run on the staged sibling **before**
    ///   the old final path is replaced.
    static func finalizeCompressionDestination(
        _ destination: CompressionDestination,
        fileManager: FileManager = .default,
        beforeCommit: ((URL) throws -> Void)? = nil
    ) throws {
        guard destination.shouldRelocate else {
            // Non-relocate paths are not used by current backends (always temp → final).
            if let beforeCommit {
                try beforeCommit(destination.workURL)
            }
            return
        }

        let workURL = destination.workURL
        let finalURL = destination.finalURL
        guard fileManager.fileExists(atPath: workURL.path) else {
            throw ArchiveError.commandFailed("Archive was not created.")
        }

        let parent = finalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        // Sibling keeps a real archive extension so tools/verify recognize the format
        // (hidden name: .ArchivePeek-<uuid>.zip / .tar.gz / …).
        let suffix = archiveFileSuffix(for: finalURL, workURL: workURL)
        let partialURL = parent.appendingPathComponent(
            ".ArchivePeek-\(UUID().uuidString).\(suffix)"
        )

        // Stage beside the final path. Never delete or open finalURL yet.
        do {
            do {
                try fileManager.moveItem(at: workURL, to: partialURL)
            } catch {
                // Cross-volume move fails → copy then remove work.
                try fileManager.copyItem(at: workURL, to: partialURL)
                try? fileManager.removeItem(at: workURL)
            }
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw ArchiveError.commandFailed(
                "Could not stage the archive next to \(finalURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        do {
            if let beforeCommit {
                try beforeCommit(partialURL)
            }

            if fileManager.fileExists(atPath: finalURL.path) {
                // Same-directory atomic replacement: old final is only swapped out as part of
                // a successful commit, not deleted first.
                _ = try fileManager.replaceItemAt(
                    finalURL,
                    withItemAt: partialURL,
                    backupItemName: nil,
                    options: []
                )
                // replaceItemAt usually consumes the new item; clean leftover partial if any.
                if fileManager.fileExists(atPath: partialURL.path) {
                    try? fileManager.removeItem(at: partialURL)
                }
            } else {
                try fileManager.moveItem(at: partialURL, to: finalURL)
            }
            // The new single file replaces an older split set of the same name.
            // Leaving `Name.7z.001` or `Name.z01` would make the next open read the old volumes.
            removeSupersededSplitVolumes(beside: finalURL, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: partialURL)
            // If work was already moved into partial, nothing left at workURL.
            try? fileManager.removeItem(at: workURL)
            // Verify runs inside this do. Cancel during "Verifying integrity…" must stay
            // a cancellation. The staged sibling is already removed; the previous archive is untouched.
            if let archiveError = error as? ArchiveError, case .cancelled = archiveError {
                throw ArchiveError.cancelled
            }
            throw ArchiveError.commandFailed(
                "Could not save the archive to \(finalURL.path): \(error.localizedDescription)"
            )
        }
    }

    static func cleanupCompressionDestination(
        _ destination: CompressionDestination,
        fileManager: FileManager = .default
    ) {
        // Only the system-temp work file. Destination-directory siblings are cleaned
        // by finalizeCompressionDestination on its own failure path (do not scan the folder —
        // another concurrent compress might own a partial there).
        if destination.shouldRelocate {
            for url in createdVolumes(fromWorkBase: destination.workURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: destination.workURL.path) {
                try? fileManager.removeItem(at: destination.workURL)
            }
        }
    }

    /// Volumes written next to a work base (`archive.7z` → `archive.7z.001`, or `archive.part1.rar`).
    static func createdVolumes(
        fromWorkBase workURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let firstNumeric = URL(fileURLWithPath: workURL.path + ".001")
        if fileManager.fileExists(atPath: firstNumeric.path) {
            return SplitArchive.set(for: firstNumeric, fileManager: fileManager)?.volumes ?? [firstNumeric]
        }
        let stem = workURL.deletingPathExtension().lastPathComponent
        let parent = workURL.deletingLastPathComponent()
        for part in ["\(stem).part1.rar", "\(stem).part01.rar"] {
            let url = parent.appendingPathComponent(part)
            if fileManager.fileExists(atPath: url.path) {
                return SplitArchive.set(for: url, fileManager: fileManager)?.volumes ?? [url]
            }
        }
        if let split = SplitArchive.set(for: workURL, fileManager: fileManager), split.isMultiVolume {
            return split.volumes
        }
        if fileManager.fileExists(atPath: workURL.path) {
            return [workURL]
        }
        return []
    }

    static func mapWorkVolume(
        _ workVolume: URL,
        workBase: URL,
        finalBase: URL
    ) -> URL {
        let parent = finalBase.deletingLastPathComponent()
        let workName = workVolume.lastPathComponent
        let workBaseName = workBase.lastPathComponent
        let finalBaseName = finalBase.lastPathComponent
        if workName.compare(workBaseName, options: .caseInsensitive) == .orderedSame {
            return parent.appendingPathComponent(finalBaseName)
        }
        if workName.lowercased().hasPrefix(workBaseName.lowercased() + ".") {
            let extra = String(workName.dropFirst(workBaseName.count))
            return parent.appendingPathComponent(finalBaseName + extra)
        }
        let workStem = (workBaseName as NSString).deletingPathExtension
        let finalStem = (finalBaseName as NSString).deletingPathExtension
        if let range = workName.range(of: workStem, options: .caseInsensitive) {
            var mapped = workName
            mapped.replaceSubrange(range, with: finalStem)
            return parent.appendingPathComponent(mapped)
        }
        return parent.appendingPathComponent(workName)
    }

    /// Volumes that a split create would replace next to `finalBase` (`Backup.7z` → `Backup.7z.001`, …).
    static func existingSplitDestinations(
        for finalBase: URL,
        format: CompressFormat,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []
        let firstNumeric = URL(fileURLWithPath: finalBase.path + ".001")
        if fileManager.fileExists(atPath: firstNumeric.path) {
            urls.append(contentsOf: SplitArchive.set(for: firstNumeric, fileManager: fileManager)?.volumes ?? [firstNumeric])
        }
        if format.isRar {
            let stem = finalBase.deletingPathExtension().lastPathComponent
            let parent = finalBase.deletingLastPathComponent()
            for name in ["\(stem).part1.rar", "\(stem).part01.rar"] {
                let url = parent.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    urls.append(contentsOf: SplitArchive.set(for: url, fileManager: fileManager)?.volumes ?? [url])
                }
            }
        }
        if fileManager.fileExists(atPath: finalBase.path) {
            urls.append(finalBase)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path.lowercased()).inserted }
    }

    /// Verify the temp set (shared names so 7-Zip/RAR can chain), then replace finals with rollback.
    @discardableResult
    static func finalizeSplitVolumes(
        workBase: URL,
        workVolumes: [URL],
        finalBase: URL,
        fileManager: FileManager = .default,
        beforeCommit: ((URL) throws -> Void)? = nil
    ) throws -> [URL] {
        guard !workVolumes.isEmpty else {
            throw ArchiveError.commandFailed("Split archive volumes were not created.")
        }
        if let beforeCommit, let first = workVolumes.first {
            try beforeCommit(first)
        }

        let parent = finalBase.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let batchID = UUID().uuidString

        var staged: [(partial: URL, final: URL)] = []
        do {
            for work in workVolumes {
                let finalURL = mapWorkVolume(work, workBase: workBase, finalBase: finalBase)
                let partialURL = parent.appendingPathComponent(
                    ".ArchivePeek-\(batchID).\(finalURL.lastPathComponent)"
                )
                do {
                    try fileManager.moveItem(at: work, to: partialURL)
                } catch {
                    try fileManager.copyItem(at: work, to: partialURL)
                    try? fileManager.removeItem(at: work)
                }
                staged.append((partialURL, finalURL))
            }
        } catch {
            for item in staged {
                try? fileManager.removeItem(at: item.partial)
            }
            throw ArchiveError.commandFailed(
                "Could not stage split volumes next to \(finalBase.lastPathComponent): \(error.localizedDescription)"
            )
        }

        var backups: [(backup: URL, final: URL)] = []
        var committed: [URL] = []
        do {
            for item in staged {
                if fileManager.fileExists(atPath: item.final.path) {
                    let backup = parent.appendingPathComponent(
                        ".ArchivePeek-old-\(batchID).\(item.final.lastPathComponent)"
                    )
                    try fileManager.moveItem(at: item.final, to: backup)
                    backups.append((backup, item.final))
                }
                try fileManager.moveItem(at: item.partial, to: item.final)
                committed.append(item.final)
            }

            let keep = Set(committed.map { $0.path.lowercased() })
            if let probe = committed.first,
               let oldSet = SplitArchive.set(for: probe, fileManager: fileManager) {
                for old in oldSet.volumes where !keep.contains(old.path.lowercased()) {
                    try? fileManager.removeItem(at: old)
                }
            }
            if fileManager.fileExists(atPath: finalBase.path),
               !keep.contains(finalBase.path.lowercased()) {
                try? fileManager.removeItem(at: finalBase)
            }
            for backup in backups {
                try? fileManager.removeItem(at: backup.backup)
            }
            return committed
        } catch {
            for url in committed {
                try? fileManager.removeItem(at: url)
            }
            for backup in backups {
                try? fileManager.moveItem(at: backup.backup, to: backup.final)
            }
            for item in staged {
                try? fileManager.removeItem(at: item.partial)
            }
            throw ArchiveError.commandFailed(
                "Could not save split volumes next to \(finalBase.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// File-name suffix for staging siblings (supports compound extensions like tar.gz).
    private static func archiveFileSuffix(for finalURL: URL, workURL: URL) -> String {
        let finalName = finalURL.lastPathComponent.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"] {
            if finalName.hasSuffix(".\(compound)") { return compound }
        }
        if !finalURL.pathExtension.isEmpty {
            return finalURL.pathExtension
        }
        let workName = workURL.lastPathComponent
        if let dot = workName.firstIndex(of: ".") {
            let after = String(workName[workName.index(after: dot)...])
            if !after.isEmpty { return after }
        }
        return "archive"
    }

    static func removeStaleNestedArchives(
        archive: URL,
        sources: [URL],
        fileManager: FileManager = .default
    ) throws {
        let nested = nestedArchivePathsInsideSources(archive: archive, sources: sources, fileManager: fileManager)
        guard nested.isEmpty else {
            throw ArchiveError.commandFailed(
                "A file named \"\(archive.lastPathComponent)\" already exists inside the source folder. Save the archive outside the folder being compressed, or rename/remove the existing file."
            )
        }
    }

    static func nestedArchivePathsInsideSources(
        archive: URL,
        sources: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        nestedArchivePathsMatchingOutput(archive: archive, sources: sources, fileManager: fileManager)
    }

    /// macOS noise only — never project files such as `.gitignore`.
    static let macMetadataZipExclusions: [String] = [
        ".DS_Store",
        "*/.DS_Store",
        "**/.DS_Store",
        "._*",
        "*/._*",
        "**/._*",
        "__MACOSX",
        "__MACOSX/*",
        "*/__MACOSX",
        "*/__MACOSX/*",
    ]

    static let macMetadataSevenZipExclusions: [String] = [
        ".DS_Store",
        "*/.DS_Store",
        "**/.DS_Store",
        "._*",
        "*/._*",
        "**/._*",
        "__MACOSX",
        "*/__MACOSX",
        "*/__MACOSX/*",
    ]

    static let macMetadataZipDeletionPatterns: [String] = [
        ".DS_Store",
        "*/.DS_Store",
        "*/._*",
        "__MACOSX/*",
        "*/__MACOSX/*",
    ]

    static func stripMacJunkFromZip(
        at archive: URL,
        removeCustomExclusions: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        guard let zip = ToolLocator.zipPath,
              fileManager.fileExists(atPath: archive.path) else { return }

        for pattern in macMetadataZipDeletionPatterns {
            _ = try? ProcessRunner.run(
                executable: zip,
                arguments: ["-d", archive.path, pattern]
            )
        }

        let patterns = removeCustomExclusions ? AppSettings.customExclusionPatterns : []
        let exclusions = ArchiveExclusions.Matcher(patterns: patterns)
        // Ditto and some zip runs store folder-level metadata with a literal path prefix.
        if let entries = try? ZipArchiveLister.entries(at: archive, maxEntries: 10_000) {
            for entry in entries where shouldStripFromZip(entry.path, exclusions: exclusions) {
                _ = try? ProcessRunner.run(
                    executable: zip,
                    arguments: ["-d", archive.path, entry.path]
                )
            }
        }
    }

    private static func shouldStripFromZip(
        _ path: String,
        exclusions: ArchiveExclusions.Matcher
    ) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name == "__MACOSX" { return true }
        if name.hasPrefix("._") { return true }
        if path.contains("/__MACOSX/") { return true }
        return exclusions.excludes(path)
    }

    static func zipExclusionPatterns(
        archive: URL,
        sources: [URL],
        context: Context,
        fileManager: FileManager = .default
    ) -> [String] {
        var patterns = macMetadataZipExclusions
        patterns += ArchiveExclusions.archiveToolPatterns(
            for: AppSettings.customExclusionPatterns,
            wildcards: false
        )

        for source in sources {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let relative = relativePath(for: source, from: context.workingDirectory)
            if !relative.isEmpty {
                patterns.append("\(relative)/.DS_Store")
            }
        }

        patterns += nestedArchivePathsInsideSources(archive: archive, sources: sources, fileManager: fileManager)
            .map { relativePath(for: $0, from: context.workingDirectory) }
            .filter { !$0.isEmpty }
        return patterns
    }

    static func sevenZipExclusionArguments(
        archive: URL,
        sources: [URL],
        fileManager: FileManager = .default
    ) -> [String] {
        var patterns = macMetadataSevenZipExclusions
        // 7-Zip lets `*` cross `/`. Staging already applied the stricter match.
        patterns += ArchiveExclusions.archiveToolPatterns(
            for: AppSettings.customExclusionPatterns,
            wildcards: false
        )
        patterns += nestedArchivePathsInsideSources(archive: archive, sources: sources, fileManager: fileManager)
            .map(\.path)
        return patterns.map { "-xr!\($0)" }
    }

    /// macOS junk plus Settings exclusions, as `7zz -xr!` switches.
    static func sevenZipExcludeSwitches() -> [String] {
        var patterns = macMetadataSevenZipExclusions
        patterns += ArchiveExclusions.archiveToolPatterns(
            for: AppSettings.customExclusionPatterns,
            wildcards: false
        )
        return patterns.map { "-xr!\($0)" }
    }

    /// macOS junk plus Settings exclusions, for `zip -x` and `bsdtar --exclude`.
    static func tarAndZipExcludePatterns() -> [String] {
        macMetadataZipExclusions + ArchiveExclusions.archiveToolPatterns(
            for: AppSettings.customExclusionPatterns,
            wildcards: false
        )
    }

    static func archiveIsInsideSourceTree(
        _ archive: URL,
        sources: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        // Resolve intermediate symlinks (`/var` vs `/private/var`, or a link used as a parent folder).
        // A selected symlink stays a link: its target is not the tree being packed.
        let archivePath = pathPreservingLeafSymlink(archive).path
        for source in sources {
            if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let root = pathPreservingLeafSymlink(source)
            if path(archivePath, isInsideDirectory: root.path, volumeProbe: root) {
                return true
            }
        }
        return false
    }

    /// True when both URLs name the same file. Case-insensitive volumes treat `Notes.7z` and `notes.7z` as one file.
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL
        let right = rhs.standardizedFileURL
        if let leftID = try? left.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           let rightID = try? right.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject {
            return leftID.isEqual(rightID)
        }
        if volumeIsCaseSensitive(left) {
            return left.path == right.path
        }
        return left.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            == right.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// `directory/child` is inside `directory`. On a case-insensitive volume, `Project` and `project` are the same folder.
    private static func path(_ path: String, isInsideDirectory directoryPath: String, volumeProbe: URL) -> Bool {
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if volumeIsCaseSensitive(volumeProbe) {
            return path.hasPrefix(prefix)
        }
        return path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .hasPrefix(prefix.lowercased(with: Locale(identifier: "en_US_POSIX")))
    }

    private static func volumeIsCaseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == true
    }

    /// After a single-file save, drop numbered volumes that belonged to the previous archive of this name.
    private static func removeSupersededSplitVolumes(beside finalURL: URL, fileManager: FileManager) {
        let caseSensitive = volumeIsCaseSensitive(finalURL)
        let keepPath = finalURL.standardizedFileURL.path
        let keep = caseSensitive ? keepPath : keepPath.lowercased(with: Locale(identifier: "en_US_POSIX"))
        var doomed: [URL] = []

        let numeric = URL(fileURLWithPath: finalURL.path + ".001")
        if fileManager.fileExists(atPath: numeric.path),
           let set = SplitArchive.set(for: numeric, fileManager: fileManager) {
            doomed.append(contentsOf: set.volumes)
        }

        let ext = finalURL.pathExtension.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let stem = finalURL.deletingPathExtension().lastPathComponent
        let parent = finalURL.deletingLastPathComponent()
        var companions: [String] = []
        if ext == "zip" {
            companions.append("\(stem).z01")
        } else if ext == "rar" {
            companions.append(contentsOf: [
                "\(stem).part1.rar",
                "\(stem).part01.rar",
                "\(stem).part001.rar",
                "\(stem).r00",
            ])
        }
        for name in companions {
            let url = parent.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path),
               let set = SplitArchive.set(for: url, fileManager: fileManager) {
                doomed.append(contentsOf: set.volumes)
            }
        }

        var seen = Set<String>()
        for url in doomed {
            let path = url.standardizedFileURL.path
            let key = caseSensitive ? path : path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard key != keep, seen.insert(key).inserted else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    static func sourcesIncludeDirectory(_ sources: [URL], fileManager: FileManager = .default) -> Bool {
        for source in sources {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    private static func nestedArchivePathsMatchingOutput(
        archive: URL,
        sources: [URL],
        fileManager: FileManager
    ) -> [URL] {
        let archiveName = archive.lastPathComponent
        var matches: [URL] = []
        var seen = Set<String>()

        for source in sources {
            // A selected symlink is stored as a link. Do not walk its target.
            if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let root = pathPreservingLeafSymlink(source)
            // subpathsOfDirectory does not follow a directory symlink, and it lists AppleDouble names.
            guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: root.path) else { continue }
            let caseSensitive = volumeIsCaseSensitive(root)
            for sub in subpaths {
                let name = (sub as NSString).lastPathComponent
                guard fileNamesMatch(name, archiveName, caseSensitive: caseSensitive) else { continue }
                let url = root.appendingPathComponent(sub).standardizedFileURL
                let key = caseSensitive
                    ? url.path
                    : url.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
                if seen.insert(key).inserted {
                    matches.append(url)
                }
            }
        }

        return matches
    }

    private static func fileNamesMatch(_ lhs: String, _ rhs: String, caseSensitive: Bool) -> Bool {
        if caseSensitive { return lhs == rhs }
        return lhs.lowercased(with: Locale(identifier: "en_US_POSIX"))
            == rhs.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func copyCompressItem(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        // Copy in-process on the thread that holds security-scoped access (child tools cannot inherit it).
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw ArchiveError.permissionDenied(source.lastPathComponent)
        }
    }

    private static func commonParentDirectory(for urls: [URL]) -> URL? {
        // Resolve /var vs /private/var, but keep a selected symlink as itself.
        let resolved = urls.map { pathPreservingLeafSymlink($0) }
        guard let first = resolved.first else { return nil }
        var commonComponents = first.deletingLastPathComponent().pathComponents

        for url in resolved.dropFirst() {
            let components = url.deletingLastPathComponent().pathComponents
            let limit = min(commonComponents.count, components.count)
            var shared = 0
            while shared < limit, commonComponents[shared] == components[shared] {
                shared += 1
            }
            commonComponents = Array(commonComponents.prefix(shared))
            if commonComponents.isEmpty { return nil }
        }

        guard !commonComponents.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: commonComponents), isDirectory: true)
    }

    /// Resolve intermediate symlinks such as `/var` → `/private/var`. Do not replace a symlink the user selected with its target.
    private static func pathPreservingLeafSymlink(_ url: URL) -> URL {
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if isLink {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            return parent.appendingPathComponent(url.lastPathComponent)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func relativePath(for url: URL, from directory: URL) -> String {
        // Resolve /var vs /private/var (and other symlink roots) so relative names stay correct.
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = pathPreservingLeafSymlink(url).path

        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if sourcePath == directoryPath {
            return url.lastPathComponent
        }
        if sourcePath.hasPrefix(directoryPrefix) {
            let relative = String(sourcePath.dropFirst(directoryPrefix.count))
            if !relative.isEmpty {
                return relative
            }
        }

        return url.lastPathComponent
    }
}