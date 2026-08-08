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

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
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
    /// `.gitignore`, `.build`, `node_modules`, hidden config, symlinks, packages). Only strips
    /// macOS junk (`.DS_Store`, AppleDouble `._*`, `__MACOSX`). Runs in-process with security scope.
    ///
    /// Uses whole-tree `copyItem` (not file-by-file walk) so large SwiftPM `.build` trees,
    /// `.app` bundles, and framework layouts stay intact and prepare does not hang on symlink
    /// target resolution mid-walk.
    static func stageForSevenZip(
        _ sources: [URL],
        onProgress: ((CompressionProgressUpdate) -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> StagedCompressSources {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ArchivePeek-input-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var stagedCount = 0
        for (index, source) in standardized.enumerated() {
            var isDirectory: ObjCBool = false
            // fileExists follows symlinks for the isDirectory check; also accept plain symlinks.
            let exists = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
                || ((try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
            guard exists else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }

            if shouldSkipStagingFileName(source.lastPathComponent) { continue }

            let destination = stagingRoot.appendingPathComponent(source.lastPathComponent)
            let isSymlink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let label = source.lastPathComponent
            let sizeHint = formattedSourceSize([source], fileManager: fileManager)
            let sizeSuffix = sizeHint.isEmpty ? "" : " (\(sizeHint))"
            onProgress?(CompressionProgressUpdate(
                fraction: 0,
                message: "Preparing \(label)\(sizeSuffix)… \(index + 1)/\(standardized.count)",
                indeterminate: true
            ))
            CompressDiagnostics.log("staging copy: \(source.path) → \(destination.path)")

            if isSymlink {
                // Link text only — never open the target (hangs on dead mounts / loops).
                try copySymlinkWithoutResolving(from: source, to: destination, fileManager: fileManager)
                stagedCount += 1
            } else {
                // Whole-tree copy preserves packages, symlinks, empty dirs, and hidden project files.
                try copyCompressItem(from: source, to: destination, fileManager: fileManager)
                if isDirectory.boolValue {
                    try pruneMacJunk(from: destination, fileManager: fileManager)
                    stagedCount += regularFileCount(at: destination, fileManager: fileManager)
                } else {
                    stagedCount += 1
                }
            }
            CompressDiagnostics.log("staging finished item: \(label)")
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

        CompressDiagnostics.log("staged \(stagedCount) file(s) for compression under \(stagingRoot.path)")

        return StagedCompressSources(
            urls: allStagedURLs.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            },
            cleanup: {
                try? fileManager.removeItem(at: stagingRoot)
            }
        )
    }

    /// Remove only macOS junk from an already-copied tree. Never follows symlink targets.
    private static func pruneMacJunk(from root: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }

        var toDelete: [URL] = []
        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            guard shouldSkipStagingFileName(name) else { continue }
            toDelete.append(item)
            // Skip into junk directories (e.g. __MACOSX) without resolving any symlink.
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if !isLink {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    enumerator.skipDescendants()
                }
            }
        }
        // Deepest paths first so directory removes succeed after children are gone.
        for url in toDelete.sorted(by: { $0.path.count > $1.path.count }) {
            try? fileManager.removeItem(at: url)
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

    /// Only true macOS archive noise — never project source such as `.gitignore` or `.git`.
    private static func shouldSkipStagingFileName(_ name: String) -> Bool {
        if name == ".DS_Store" || name == "__MACOSX" { return true }
        if name.hasPrefix("._") { return true }
        return false
    }

    private static func regularFileCount(at url: URL, fileManager: FileManager) -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return 1 }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }

        var count = 0
        for case let item as URL in enumerator {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }

    static func context(for sources: [URL], fileManager: FileManager = .default) throws -> Context {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        for source in standardized {
            guard fileManager.fileExists(atPath: source.path) else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }
        }

        let commonDirectory = commonParentDirectory(for: standardized) ?? standardized[0].deletingLastPathComponent()
        let itemNames = standardized.map { relativePath(for: $0, from: commonDirectory) }

        return Context(workingDirectory: commonDirectory, itemNames: itemNames)
    }

    /// Relative item names with cwd at the nearest common parent — how macOS zip expects paths.
    static func zipContext(for sources: [URL], fileManager: FileManager = .default) throws -> Context {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        for source in standardized {
            guard fileManager.fileExists(atPath: source.path) else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }
        }

        let workingDirectory = commonParentDirectory(for: standardized)
            ?? standardized[0].deletingLastPathComponent()
        let itemNames = standardized.map { relativePath(for: $0, from: workingDirectory) }

        return Context(workingDirectory: workingDirectory, itemNames: itemNames)
    }

    /// Absolute source paths with cwd at the archive's parent — used for 7-Zip.
    static func compressionInvocation(
        for sources: [URL],
        archive: URL,
        fileManager: FileManager = .default
    ) throws -> Context {
        let standardized = sources.map { $0.standardizedFileURL }
        guard !standardized.isEmpty else {
            throw ArchiveError.invalidSelection
        }

        for source in standardized {
            guard fileManager.fileExists(atPath: source.path) else {
                throw ArchiveError.entryNotFound(source.lastPathComponent)
            }
        }

        return Context(
            workingDirectory: archive.deletingLastPathComponent().standardizedFileURL,
            itemNames: standardized.map(\.path)
        )
    }

    static func normalizedArchiveURL(_ url: URL, format: CompressFormat) -> URL {
        let standardized = url.standardizedFileURL
        if hasExpectedExtension(standardized, format: format) {
            return standardized
        }

        if standardized.pathExtension.isEmpty {
            return URL(fileURLWithPath: standardized.path + "." + format.fileExtension)
        }

        return standardized
            .deletingPathExtension()
            .appendingPathExtension(format.fileExtension)
    }

    static func existingArchiveOutput(
        intended: URL,
        format: CompressFormat,
        fileManager: FileManager = .default
    ) -> URL? {
        if fileManager.fileExists(atPath: intended.path) {
            return intended
        }

        if intended.pathExtension.isEmpty {
            let autoAdded = URL(fileURLWithPath: intended.path + "." + format.fileExtension)
            if fileManager.fileExists(atPath: autoAdded.path) {
                return autoAdded
            }
        }

        return nil
    }

    static func hasExpectedExtension(_ url: URL, format: CompressFormat) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let expected = format.fileExtension.lowercased()
        if expected.contains(".") {
            return name.hasSuffix(".\(expected)")
        }
        return url.pathExtension.lowercased() == expected
    }

    static func proposedArchiveName(for sources: [URL], format: CompressFormat) -> String {
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
        return "\(baseName).\(format.fileExtension)"
    }

    static func uniqueArchiveURL(
        proposedName: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let initial = directory.appendingPathComponent(proposedName)
        guard fileManager.fileExists(atPath: initial.path) else { return initial }

        let base = (proposedName as NSString).deletingPathExtension
        let ext = (proposedName as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"

        for index in 2...999 {
            let candidate = directory.appendingPathComponent("\(base) \(index)\(suffix)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6))\(suffix)")
    }

    static func compressionDestination(
        archive: URL,
        sources: [URL],
        format: CompressFormat,
        fileManager: FileManager = .default
    ) -> CompressionDestination {
        let finalURL = archive.standardizedFileURL
        if archiveIsInsideSourceTree(finalURL, sources: sources, fileManager: fileManager) {
            return temporaryCompressionDestination(archive: finalURL, format: format, fileManager: fileManager)
        }
        return CompressionDestination(workURL: finalURL, finalURL: finalURL, shouldRelocate: false)
    }

    /// Build in a temp file first, then move into place with app security scope (child tools cannot write to TCC paths).
    static func temporaryCompressionDestination(
        archive: URL,
        format: CompressFormat,
        fileManager: FileManager = .default
    ) -> CompressionDestination {
        let finalURL = archive.standardizedFileURL
        let ext = finalURL.pathExtension.isEmpty ? format.fileExtension : finalURL.pathExtension
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("ArchivePeek-\(UUID().uuidString).\(ext)")
        return CompressionDestination(workURL: temp, finalURL: finalURL, shouldRelocate: true)
    }

    static func finalizeCompressionDestination(
        _ destination: CompressionDestination,
        fileManager: FileManager = .default
    ) throws {
        guard destination.shouldRelocate else { return }

        let parent = destination.finalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.finalURL.path) {
            try fileManager.removeItem(at: destination.finalURL)
        }
        do {
            try fileManager.moveItem(at: destination.workURL, to: destination.finalURL)
        } catch {
            do {
                if fileManager.fileExists(atPath: destination.finalURL.path) {
                    try fileManager.removeItem(at: destination.finalURL)
                }
                try fileManager.copyItem(at: destination.workURL, to: destination.finalURL)
                try fileManager.removeItem(at: destination.workURL)
            } catch {
                throw ArchiveError.commandFailed(
                    "Could not save the archive to \(destination.finalURL.path): \(error.localizedDescription)"
                )
            }
        }
    }

    static func cleanupCompressionDestination(
        _ destination: CompressionDestination,
        fileManager: FileManager = .default
    ) {
        if destination.shouldRelocate,
           fileManager.fileExists(atPath: destination.workURL.path) {
            try? fileManager.removeItem(at: destination.workURL)
        }
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
        "*.DS_Store",
        "*/._*",
        "__MACOSX/*",
        "*/__MACOSX/*",
    ]

    static func stripMacJunkFromZip(
        at archive: URL,
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

        // Ditto and some zip runs store folder-level metadata with a literal path prefix.
        if let entries = try? ZipArchiveLister.entries(at: archive, maxEntries: 10_000) {
            for entry in entries where shouldStripFromZip(entry.path) {
                _ = try? ProcessRunner.run(
                    executable: zip,
                    arguments: ["-d", archive.path, entry.path]
                )
            }
        }
    }

    private static func shouldStripFromZip(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name == "__MACOSX" { return true }
        if name.hasPrefix("._") { return true }
        return path.contains("/__MACOSX/")
    }

    static func zipExclusionPatterns(
        archive: URL,
        sources: [URL],
        context: Context,
        fileManager: FileManager = .default
    ) -> [String] {
        var patterns = macMetadataZipExclusions

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
        patterns += nestedArchivePathsInsideSources(archive: archive, sources: sources, fileManager: fileManager)
            .map(\.path)
        return patterns.map { "-xr!\($0)" }
    }

    static func archiveIsInsideSourceTree(
        _ archive: URL,
        sources: [URL],
        fileManager: FileManager = .default
    ) -> Bool {
        let archivePath = archive.standardizedFileURL.path
        for source in sources {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let root = source.standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if archivePath.hasPrefix(prefix) {
                return true
            }
        }
        return false
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

        for source in sources {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let candidate = source.appendingPathComponent(archiveName)
            if fileManager.fileExists(atPath: candidate.path) {
                matches.append(candidate.standardizedFileURL)
            }
        }

        return matches
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
        guard let first = urls.first else { return nil }
        var commonComponents = first.deletingLastPathComponent().pathComponents

        for url in urls.dropFirst() {
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

    private static func relativePath(for url: URL, from directory: URL) -> String {
        let directoryPath = directory.standardizedFileURL.path
        let sourcePath = url.standardizedFileURL.path

        if sourcePath.hasPrefix(directoryPath) {
            var relative = String(sourcePath.dropFirst(directoryPath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            if !relative.isEmpty {
                return relative
            }
        }

        return url.lastPathComponent
    }
}