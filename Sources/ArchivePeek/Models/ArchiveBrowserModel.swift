import AppKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers
@MainActor
final class ArchiveBrowserModel: ObservableObject {
    @Published var archiveURL: URL?
    @Published var listing: ArchiveListing?
    @Published var currentPath: String = ""
    @Published var selection: Set<String> = []
    @Published private(set) var visibleEntries: [ArchiveEntry] = []
    @Published var isLoading = false
    @Published var statusMessage = "Open an archive to browse its contents."
    @Published var errorMessage: String?
    @Published var password: String = ""
    @Published var passwordErrorMessage: String?
    @Published var needsPassword = false
    @Published var showCompressSheet = false
    @Published var showHelpSheet = false
    @Published var compressSources: [URL] = []
    @Published var compressFormat: CompressFormat = .defaultFormat
    @Published var compressionLevel = 5
    @Published var compressPassword = ""
    @Published var compressSolidArchive = false
    @Published var compressDmgAppInstaller = false
    /// When format is ZIP, write a comic-book ZIP (`.cbz`) instead of `.zip`.
    @Published var compressSaveAsComicBookZip = false
    @Published var verifyAfterCompress = true
    @Published var isCompressing = false
    @Published var compressProgress: Double = 0
    @Published var compressProgressMessage = "Preparing…"
    @Published var compressProgressIndeterminate = false
    @Published var isDropTargeted = false
    @Published private(set) var isPreviewing = false

    private var compressionHandle: ProcessRunner.Handle?
    /// Cancels in-flight extract / open / verify subprocesses when closing or switching archives.
    private var operationHandle: ProcessRunner.Handle?
    /// Cancels the active archive list process when reloading or closing.
    private var loadHandle: ProcessRunner.Handle?
    private var folderIndex: ArchiveFolderIndex?
    private var entriesByLookupKey: [String: ArchiveEntry] = [:]
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var archiveAccessTokens: [SecurityScopedAccess.Token] = []
    private var previewGeneration = 0
    private var dragOutPrepared: [String: URL] = [:]
    private var dragOutTasks: [String: Task<Void, Never>] = [:]
    private var dragOutHandles: [String: ProcessRunner.Handle] = [:]
    private var compressAccessTokens: [SecurityScopedAccess.Token] = []
    private var compressGeneration = 0

    init() {
        AppSettings.applyCompressionDefaults(to: self)
    }

    var breadcrumbSegments: [(label: String, path: String)] {
        var segments: [(String, String)] = [("Archive", "")]
        guard !currentPath.isEmpty else { return segments }

        var accumulated = ""
        for component in currentPath.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(component) : accumulated + "/" + component
            segments.append((String(component), accumulated))
        }
        return segments
    }

    var isBrowsingArchive: Bool {
        listing != nil
    }

    var hasOpenArchive: Bool {
        archiveURL != nil
    }

    var isViewingArchive: Bool {
        isBrowsingArchive || needsPassword
    }

    func closeArchive() {
        loadTask?.cancel()
        loadHandle?.cancel()
        compressionHandle?.cancel()
        operationHandle?.cancel()
        loadGeneration += 1
        operationGeneration += 1
        compressGeneration += 1
        previewGeneration += 1
        isPreviewing = false
        clearDragOutCache()
        QLPreviewPanel.shared()?.orderOut(nil)
        QuickLookCoordinator.shared.previewURL = nil
        releaseSecurityScopedAccess()

        archiveURL = nil
        listing = nil
        currentPath = ""
        selection.removeAll()
        password = ""
        passwordErrorMessage = nil
        needsPassword = false
        errorMessage = nil
        isLoading = false

        rebuildFolderIndex()
        statusMessage = "Open an archive to browse its contents."
    }

    func openArchive(_ url: URL, accessTokens: [SecurityScopedAccess.Token] = []) {
        loadTask?.cancel()
        loadHandle?.cancel()
        // Cancel extract/open/verify against the previous archive; loadArchive bumps loadGeneration.
        operationHandle?.cancel()
        operationGeneration += 1
        previewGeneration += 1
        clearDragOutCache()
        releaseSecurityScopedAccess()

        let standardized = url.standardizedFileURL
        archiveURL = standardized
        currentPath = ""
        selection.removeAll()
        password = ""
        passwordErrorMessage = nil
        errorMessage = nil
        needsPassword = false
        listing = nil
        rebuildFolderIndex()
        acquireSecurityScopedAccess(for: [standardized], capturedTokens: accessTokens)
        loadArchive()
    }

    /// Start a cancellable archive operation (extract / open / verify / preview).
    private func beginOperationHandle() -> ProcessRunner.Handle {
        operationHandle?.cancel()
        let handle = ProcessRunner.Handle()
        operationHandle = handle
        return handle
    }

    func unlockArchiveWithPassword() {
        passwordErrorMessage = nil
        loadArchive()
    }

    func loadArchive() {
        guard let archiveURL else { return }

        // Always bump generation so a cancelled prior load (e.g. password retry) cannot
        // clear isLoading while a newer load with the same generation is still running.
        loadTask?.cancel()
        loadHandle?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let requestURL = archiveURL
        let requestPassword = password.isEmpty ? nil : password
        let handle = ProcessRunner.Handle()
        loadHandle = handle

        isLoading = true
        errorMessage = nil
        statusMessage = "Reading \(requestURL.lastPathComponent)..."

        loadTask = Task {
            defer {
                if generation == loadGeneration {
                    isLoading = false
                }
            }
            do {
                let result = try await ArchiveEngine.list(
                    url: requestURL,
                    password: requestPassword,
                    handle: handle
                )
                guard !Task.isCancelled,
                      generation == loadGeneration,
                      archiveURL == requestURL else { return }

                listing = result
                rebuildFolderIndex()
                needsPassword = false
                passwordErrorMessage = nil
                statusMessage = result.summary
            } catch ArchiveError.cancelled {
                guard generation == loadGeneration else { return }
                // Superseded by a newer load or close — leave UI to the new operation.
            } catch ArchiveError.passwordRequired {
                guard !Task.isCancelled,
                      generation == loadGeneration,
                      archiveURL == requestURL else { return }

                needsPassword = true
                listing = nil
                rebuildFolderIndex()
                passwordErrorMessage = password.isEmpty
                    ? nil
                    : "Incorrect password. Try again."
                statusMessage = "Password required."
            } catch {
                guard !Task.isCancelled,
                      generation == loadGeneration,
                      archiveURL == requestURL else { return }

                let message = error.localizedDescription
                closeArchive()
                errorMessage = message
                statusMessage = "Failed to open archive."
            }
        }
    }

    func navigateTo(path: String) {
        currentPath = path
        selection.removeAll()
        refreshVisibleEntries()
    }

    func openSelectedEntry() {
        guard let entry = selectedVisibleEntries().first else {
            errorMessage = "Select a file or folder to open."
            return
        }
        openEntry(entry)
    }

    func entry(atVisibleRow row: Int) -> ArchiveEntry? {
        guard row >= 0, row < visibleEntries.count else { return nil }
        return visibleEntries[row]
    }

    func openEntry(_ entry: ArchiveEntry) {
        if entry.isDirectory {
            navigateTo(path: entry.normalizedPath)
            return
        }
        Task { await openFile(entry) }
    }

    func extractSelected(preservePaths: Bool = false) {
        guard listing != nil else { return }
        let selectedEntries = selectedFileEntries()
        guard !selectedEntries.isEmpty else {
            errorMessage = "Select one or more files to extract."
            return
        }
        chooseDestination { destination, tokens in
            Task {
                await self.extract(
                    entries: selectedEntries,
                    to: destination,
                    preservePaths: preservePaths,
                    destinationTokens: tokens
                )
            }
        }
    }

    func extractEntry(_ entry: ArchiveEntry, preservePaths: Bool = false) {
        guard listing != nil, !entry.isDirectory else { return }
        let canonical = canonicalEntry(for: entry)
        chooseDestination { destination, tokens in
            Task {
                await self.extract(
                    entries: [canonical],
                    to: destination,
                    preservePaths: preservePaths,
                    destinationTokens: tokens
                )
            }
        }
    }

    func extractAll() {
        guard archiveURL != nil else { return }
        chooseDestination { destination, tokens in
            Task { await self.extractAll(to: destination, destinationTokens: tokens) }
        }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        let standardized = urls.map { $0.standardizedFileURL }
        let tokens = SecurityScopedAccess.captureTokens(for: standardized)
        let archives = standardized.filter { ArchiveFormatCatalog.isArchive($0) }
        let compressibles = standardized.filter { !ArchiveFormatCatalog.isArchive($0) }

        if let archive = archives.first {
            let archiveTokens = tokens.filter { $0.url == archive }
            openArchive(archive, accessTokens: archiveTokens)
            if archives.count > 1 {
                statusMessage = "Opened \(archive.lastPathComponent). \(archives.count - 1) additional archive(s) were not opened."
            }
        }

        guard !compressibles.isEmpty else {
            if archives.isEmpty {
                errorMessage = "Drop archives to open them, or files and folders to compress."
            }
            return
        }

        let compressTokens = tokens.filter { token in
            compressibles.contains(token.url)
        }
        integrateCompressSources(compressibles, tokens: compressTokens)
        if archives.isEmpty {
            presentCompressSheet()
        } else {
            statusMessage = "Opened \(archives[0].lastPathComponent). Added \(compressibles.count) item(s) to compress."
        }
    }

    func prepareDragOut(for entry: ArchiveEntry) {
        guard let archiveURL else { return }
        let canonical = canonicalEntry(for: entry)
        let key = canonical.path
        guard dragOutPrepared[key] == nil, dragOutTasks[key] == nil else { return }

        let sourceArchive = archiveURL
        let requestPassword = password.isEmpty ? nil : password
        let accessTokens = archiveAccessTokens
        let catalogEntries = listing?.entries ?? []
        let handle = ProcessRunner.Handle()
        dragOutHandles[key] = handle

        dragOutTasks[key] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                _ = SecurityScopedAccess.activate(accessTokens)
                defer { SecurityScopedAccess.deactivate(accessTokens) }

                let extracted = try await ArchiveEngine.extractToTemp(
                    entry: canonical,
                    from: sourceArchive,
                    password: requestPassword,
                    catalogEntries: catalogEntries,
                    handle: handle
                )
                await MainActor.run {
                    self.dragOutPrepared[key] = extracted
                    self.dragOutTasks[key] = nil
                    self.dragOutHandles[key] = nil
                }
            } catch {
                await MainActor.run {
                    self.dragOutTasks[key] = nil
                    self.dragOutHandles[key] = nil
                }
            }
        }
    }

    func preparedDragURL(for entry: ArchiveEntry) -> URL? {
        dragOutPrepared[canonicalEntry(for: entry).path]
    }

    func writeDraggedEntryToPromise(_ entry: ArchiveEntry, url: URL, completion: @escaping (Error?) -> Void) {
        guard let archiveURL else {
            completion(ArchiveError.invalidSelection)
            return
        }
        let canonical = canonicalEntry(for: entry)
        let sourceArchive = archiveURL
        let requestPassword = password.isEmpty ? nil : password
        let accessTokens = archiveAccessTokens
        let key = canonical.path
        let handle = ProcessRunner.Handle()
        dragOutHandles[key] = handle

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(ArchiveError.cancelled) }
                return
            }
            do {
                let extracted: URL
                let catalogEntries = await MainActor.run { self.listing?.entries ?? [] }
                if let cached = await MainActor.run(body: { self.preparedDragURL(for: canonical) }) {
                    extracted = cached
                } else {
                    _ = SecurityScopedAccess.activate(accessTokens)
                    defer { SecurityScopedAccess.deactivate(accessTokens) }
                    extracted = try await ArchiveEngine.extractToTemp(
                        entry: canonical,
                        from: sourceArchive,
                        password: requestPassword,
                        catalogEntries: catalogEntries,
                        handle: handle
                    )
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: extracted, to: url)
                await MainActor.run { self.dragOutHandles[key] = nil }
                DispatchQueue.main.async {
                    completion(nil)
                }
            } catch {
                await MainActor.run { self.dragOutHandles[key] = nil }
                DispatchQueue.main.async {
                    completion(error)
                }
            }
        }
    }

    func presentCompressSheet(with sources: [URL] = []) {
        AppSettings.applyCompressionDefaults(to: self)
        if !sources.isEmpty {
            mergeCompressSources(sources)
        }
        showCompressSheet = true
    }

    func closeCompressSheet() {
        showCompressSheet = false
        compressPassword = ""
        compressSources.removeAll()
        compressDmgAppInstaller = AppSettings.defaultDmgAppInstaller
        compressSaveAsComicBookZip = AppSettings.defaultComicBookZip && AppSettings.defaultCompressFormat.isZip
        releaseCompressAccess()
    }

    /// True when ZIP output should use the comic-book (`.cbz`) extension.
    var saveAsComicBookZip: Bool {
        compressFormat.isZip && compressSaveAsComicBookZip
    }

    var canCreateDmgAppInstaller: Bool {
        compressFormat.isDmg &&
            !compressSources.isEmpty &&
            !CompressionSupport.applicationBundles(in: compressSources).isEmpty
    }

    func addCompressSources() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select the folder or files to compress. Pick everything in this one step to avoid extra permission prompts."
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls.map { $0.standardizedFileURL }
            let tokens = SecurityScopedAccess.captureTokens(for: urls)
            Task { @MainActor in
                self.integrateCompressSources(urls, tokens: tokens)
            }
        }
    }

    func removeCompressSource(_ url: URL) {
        let standardized = url.standardizedFileURL
        compressSources.removeAll { $0 == standardized }
        SecurityScopedAccess.removeToken(for: standardized, from: &compressAccessTokens)
    }

    func cancelCompression() {
        compressionHandle?.cancel()
        statusMessage = "Stopping compression…"
    }

    func chooseCompressDestination() {
        guard !compressSources.isEmpty else {
            errorMessage = ArchiveError.invalidSelection.localizedDescription
            return
        }

        if compressFormat.requiresSingleFile && compressSources.count != 1 {
            errorMessage = "\(compressFormat.label) archives can only contain a single file."
            return
        }

        // App installer layout is DMG-only. Ignore a stale true flag on ZIP/7z/etc.
        // (Previously: defaultDmgAppInstaller + non-DMG format always failed Create Archive.)
        if compressFormat.isDmg && compressDmgAppInstaller && !canCreateDmgAppInstaller {
            errorMessage = "App installer layout requires at least one top-level .app bundle. Use DMG with a selected .app, or turn off App installer layout."
            return
        }
        if !compressFormat.isDmg {
            compressDmgAppInstaller = false
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let comicBookZip = saveAsComicBookZip
        panel.nameFieldStringValue = CompressionSupport.proposedArchiveName(
            for: compressSources,
            format: compressFormat,
            comicBookZip: comicBookZip
        )
        panel.allowedContentTypes = allowedSaveTypes(for: compressFormat, comicBookZip: comicBookZip)
        panel.prompt = "Create"
        panel.message = "Save the archive outside the folder being compressed (for example, on Desktop)."
        let format = compressFormat

        panel.begin { response in
            guard response == .OK, let picked = panel.url else { return }
            let destination = CompressionSupport.normalizedArchiveURL(
                picked.standardizedFileURL,
                format: format,
                comicBookZip: comicBookZip
            )
            let destinationTokens = SecurityScopedAccess.captureTokens(for: [destination])
            Task { @MainActor in
                self.appendCompressTokens(destinationTokens)
                self.showCompressSheet = false
                await self.compress(to: destination)
            }
        }
    }

    private func allowedSaveTypes(for format: CompressFormat, comicBookZip: Bool = false) -> [UTType] {
        // Prefer the dedicated CBZ UTI (conforms to public.zip-archive) so Finder uses a ZIP-style
        // icon instead of mapping through com.archivepeek.archive / another comic app’s icon.
        if format.isZip && comicBookZip {
            if let cbz = UTType(ArchiveFormatCatalog.cbzTypeIdentifier) {
                return [cbz]
            }
            return [.zip]
        }
        let ext = format.outputExtension(comicBookZip: comicBookZip)
        if let type = UTType(filenameExtension: ext) {
            return [type]
        }
        return [.data]
    }

    func verifyOpenArchive() {
        guard let archiveURL else { return }
        Task {
            await verifyArchive(
                at: archiveURL,
                password: password.isEmpty ? nil : password,
                label: archiveURL.lastPathComponent
            )
        }
    }

    func quickLookSelected() {
        guard listing != nil else { return }
        guard let entry = selectedFileEntries().first else {
            errorMessage = "Select a file to preview."
            return
        }
        Task { await preview(entry) }
    }

    func previewEntry(_ entry: ArchiveEntry) {
        guard listing != nil, !entry.isDirectory else { return }
        Task { await preview(entry) }
    }

    private func extract(
        entries: [ArchiveEntry],
        to destination: URL,
        preservePaths: Bool,
        destinationTokens: [SecurityScopedAccess.Token]
    ) async {
        let generation = operationGeneration
        guard let archiveURL else { return }
        let sourceArchive = archiveURL
        let requestPassword = password.isEmpty ? nil : password

        // Prefer bookmarks captured in the panel callback (before the async hop).
        var heldTokens = destinationTokens
        if heldTokens.isEmpty {
            heldTokens = SecurityScopedAccess.captureTokens(for: [
                destination,
                destination.deletingLastPathComponent(),
            ])
        }
        _ = SecurityScopedAccess.activate(heldTokens)
        defer { SecurityScopedAccess.releaseAll(&heldTokens) }

        let handle = beginOperationHandle()
        isLoading = true
        defer {
            if generation == operationGeneration {
                isLoading = false
            }
        }
        statusMessage = "Extracting \(entries.count) item(s)..."
        do {
            try await ArchiveEngine.extract(
                entries: entries,
                from: sourceArchive,
                to: destination,
                preservePaths: preservePaths,
                password: requestPassword,
                handle: handle
            )
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }

            statusMessage = "Extracted \(entries.count) item(s) to \(destination.path)."
            let revealed = entries.compactMap { entry -> URL? in
                if preservePaths {
                    return try? PathSafety.resolvedURL(forEntryPath: entry.path, in: destination)
                }
                return destination.appendingPathComponent(entry.displayName)
            }
            if !revealed.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(revealed)
            }
        } catch ArchiveError.cancelled {
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            statusMessage = "Extraction cancelled."
        } catch {
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Extraction failed."
        }
    }

    private func extractAll(
        to destination: URL,
        destinationTokens: [SecurityScopedAccess.Token]
    ) async {
        let generation = operationGeneration
        guard let archiveURL else { return }
        let sourceArchive = archiveURL

        var heldTokens = destinationTokens
        if heldTokens.isEmpty {
            heldTokens = SecurityScopedAccess.captureTokens(for: [
                destination,
                destination.deletingLastPathComponent(),
            ])
        }
        _ = SecurityScopedAccess.activate(heldTokens)
        defer { SecurityScopedAccess.releaseAll(&heldTokens) }

        let handle = beginOperationHandle()
        isLoading = true
        defer {
            if generation == operationGeneration {
                isLoading = false
            }
        }
        statusMessage = "Extracting all contents..."
        do {
            try await ArchiveEngine.extractAll(
                from: sourceArchive,
                to: destination,
                password: password.isEmpty ? nil : password,
                handle: handle
            )
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            statusMessage = "Extracted archive to \(destination.path)."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch ArchiveError.cancelled {
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            statusMessage = "Extraction cancelled."
        } catch {
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Extraction failed."
        }
    }

    private func openFile(_ entry: ArchiveEntry) async {
        let generation = operationGeneration
        guard let archiveURL else { return }
        let sourceArchive = archiveURL
        let canonical = canonicalEntry(for: entry)
        let handle = beginOperationHandle()
        isLoading = true
        defer {
            if generation == operationGeneration {
                isLoading = false
            }
        }
        statusMessage = "Opening \(canonical.displayName)..."
        do {
            let extracted = try await ArchiveEngine.extractToTemp(
                entry: canonical,
                from: sourceArchive,
                password: password.isEmpty ? nil : password,
                catalogEntries: listing?.entries ?? [],
                handle: handle
            )
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            NSWorkspace.shared.open(extracted)
            statusMessage = "Opened \(canonical.displayName)."
        } catch ArchiveError.cancelled {
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            statusMessage = "Open cancelled."
        } catch {
            guard generation == operationGeneration, archiveURL == sourceArchive else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Could not open file."
        }
    }

    private func verifyArchive(at url: URL, password: String?, label: String) async {
        let generation = operationGeneration
        let requestURL = archiveURL
        let accessTokens = archiveAccessTokens
        let handle = beginOperationHandle()
        isLoading = true
        defer {
            if generation == operationGeneration {
                isLoading = false
            }
        }
        errorMessage = nil
        statusMessage = "Verifying \(label)…"
        do {
            let message = try await ArchiveEngine.verifyIntegrity(
                url: url,
                password: password,
                accessTokens: accessTokens,
                handle: handle
            )
            guard generation == operationGeneration, archiveURL == requestURL else { return }
            statusMessage = message.localizedCaseInsensitiveContains("passed")
                ? "Integrity check passed for \(label)."
                : message
        } catch ArchiveError.cancelled {
            guard generation == operationGeneration, archiveURL == requestURL else { return }
            statusMessage = "Verification cancelled."
        } catch ArchiveError.passwordRequired {
            guard generation == operationGeneration, archiveURL == requestURL else { return }
            needsPassword = true
            passwordErrorMessage = password?.isEmpty == false
                ? "Incorrect password. Try again."
                : nil
            statusMessage = "Password required to verify \(label)."
        } catch {
            guard generation == operationGeneration, archiveURL == requestURL else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Integrity check failed for \(label)."
        }
    }

    private func preview(_ entry: ArchiveEntry) async {
        let generation = previewGeneration
        guard let archiveURL else { return }
        let sourceArchive = archiveURL
        let canonical = canonicalEntry(for: entry)
        let requestPassword = password.isEmpty ? nil : password
        let accessTokens = archiveAccessTokens
        let catalogEntries = listing?.entries ?? []
        let handle = beginOperationHandle()

        isPreviewing = true
        statusMessage = "Preparing preview for \(canonical.displayName)…"
        errorMessage = nil
        defer {
            if generation == previewGeneration {
                isPreviewing = false
            }
        }

        do {
            let extracted = try await Task.detached(priority: .userInitiated) {
                _ = SecurityScopedAccess.activate(accessTokens)
                defer { SecurityScopedAccess.deactivate(accessTokens) }
                return try await ArchiveEngine.extractToTemp(
                    entry: canonical,
                    from: sourceArchive,
                    password: requestPassword,
                    catalogEntries: catalogEntries,
                    handle: handle
                )
            }.value

            guard generation == previewGeneration, archiveURL == sourceArchive else { return }

            TempFileRegistry.setPreviewRoot(extracted.deletingLastPathComponent())
            if let panel = QLPreviewPanel.shared() {
                panel.dataSource = QuickLookCoordinator.shared
                panel.delegate = QuickLookCoordinator.shared
                QuickLookCoordinator.shared.previewURL = extracted
                panel.reloadData()
                panel.makeKeyAndOrderFront(nil)
            } else {
                NSWorkspace.shared.open(extracted)
            }
            statusMessage = "Previewing \(canonical.displayName)."
        } catch ArchiveError.cancelled {
            guard generation == previewGeneration else { return }
            statusMessage = "Preview cancelled."
        } catch {
            guard generation == previewGeneration, archiveURL == sourceArchive else { return }
            errorMessage = error.localizedDescription
            statusMessage = "Preview failed."
        }
    }

    private func rebuildFolderIndex() {
        guard let listing else {
            folderIndex = nil
            entriesByLookupKey = [:]
            visibleEntries = []
            return
        }
        folderIndex = ArchiveFolderIndex(entries: listing.entries)
        rebuildEntryLookup(from: listing.entries)
        refreshVisibleEntries()
    }

    private func refreshVisibleEntries() {
        visibleEntries = folderIndex?.children(at: currentPath) ?? []
    }

    private func rebuildEntryLookup(from entries: [ArchiveEntry]) {
        var lookup: [String: ArchiveEntry] = [:]
        for entry in entries {
            for key in pathLookupKeys(for: entry) {
                lookup[key] = entry
            }
        }
        entriesByLookupKey = lookup
    }

    private func pathLookupKeys(for entry: ArchiveEntry) -> [String] {
        let normalized = entry.normalizedPath
        var keys: Set<String> = [entry.path, normalized, entry.id]
        if entry.isDirectory {
            keys.insert(normalized + "/")
            if !entry.path.hasSuffix("/") {
                keys.insert(entry.path + "/")
            }
        }
        return Array(keys)
    }

    private func canonicalEntry(for entry: ArchiveEntry) -> ArchiveEntry {
        for key in pathLookupKeys(for: entry) {
            if let match = entriesByLookupKey[key] {
                return match
            }
        }
        return entry
    }

    private func selectedVisibleEntries() -> [ArchiveEntry] {
        visibleEntries.filter { entry in
            pathLookupKeys(for: entry).contains { selection.contains($0) }
        }
    }

    private func selectedFileEntries() -> [ArchiveEntry] {
        selectedVisibleEntries()
            .filter { !$0.isDirectory }
            .map { canonicalEntry(for: $0) }
    }

    func mergeCompressSourcesFromDrop(_ urls: [URL]) {
        mergeCompressSources(urls)
    }

    private func mergeCompressSources(_ urls: [URL]) {
        let standardized = urls.map { $0.standardizedFileURL }
        let tokens = SecurityScopedAccess.captureTokens(for: standardized)
        integrateCompressSources(standardized, tokens: tokens)
    }

    private func integrateCompressSources(_ urls: [URL], tokens: [SecurityScopedAccess.Token]) {
        appendCompressTokens(tokens)
        let standardized = urls.map { $0.standardizedFileURL }
        for url in standardized where !compressSources.contains(url) {
            compressSources.append(url)
        }
        compressSources.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func appendCompressTokens(_ tokens: [SecurityScopedAccess.Token]) {
        for token in tokens {
            guard !compressAccessTokens.contains(where: { $0.url == token.url }) else { continue }
            compressAccessTokens.append(token)
        }
    }

    private func retainCompressAccess(for urls: [URL]) {
        SecurityScopedAccess.retainAccess(to: urls, storage: &compressAccessTokens)
    }

    private func retainCompressAccess(for url: URL) {
        retainCompressAccess(for: [url])
    }

    private func releaseCompressAccess() {
        SecurityScopedAccess.releaseAll(&compressAccessTokens)
    }

    private func compress(to destination: URL) async {
        let sourceURLs = compressSources.map { $0.standardizedFileURL }
        guard !sourceURLs.isEmpty else { return }

        let accessTokens = compressAccessTokens
        let generation = compressGeneration

        let comicBookZip = saveAsComicBookZip
        let archiveDestination = CompressionSupport.normalizedArchiveURL(
            destination,
            format: compressFormat,
            comicBookZip: comicBookZip
        )

        isCompressing = true
        compressProgress = 0
        compressProgressMessage = "Compressing…"
        compressProgressIndeterminate = true
        statusMessage = "Creating \(archiveDestination.lastPathComponent)…"
        errorMessage = nil

        let handle = ProcessRunner.Handle()
        compressionHandle = handle

        defer {
            isCompressing = false
            compressionHandle = nil
            releaseCompressAccess()
        }

        do {
            compressProgressMessage = "Preparing…"
            statusMessage = "Preparing to compress…"
            CompressDiagnostics.reset()
            CompressDiagnostics.log("UI compress requested → \(archiveDestination.path)")

            try await ArchiveEngine.compress(
                sources: sourceURLs,
                to: archiveDestination,
                format: compressFormat,
                compressionLevel: compressionLevel,
                password: compressPassword.isEmpty ? nil : compressPassword,
                solidArchive: compressSolidArchive,
                // Never pass installer layout unless format is DMG (flag can linger from Settings).
                dmgAppInstallerLayout: compressFormat.isDmg && compressDmgAppInstaller,
                // When enabled, verify the staged sibling **before** replacing any existing file.
                verifyBeforeCommit: verifyAfterCompress,
                accessTokens: accessTokens,
                handle: handle
            ) { [weak self] update in
                Task { @MainActor in
                    guard let self, generation == self.compressGeneration else { return }
                    self.compressProgress = min(max(update.fraction, 0), 1)
                    self.compressProgressMessage = update.message
                    self.compressProgressIndeterminate = update.indeterminate
                    self.statusMessage = update.message
                }
            }

            // Close archive / cancel generation must not clobber the new UI state.
            guard generation == compressGeneration else { return }

            compressProgress = 1
            compressProgressIndeterminate = false
            if verifyAfterCompress {
                statusMessage = "Created and verified \(archiveDestination.lastPathComponent)."
            } else {
                statusMessage = "Created \(archiveDestination.lastPathComponent)."
            }

            compressSources.removeAll()
            compressPassword = ""
            compressDmgAppInstaller = false
            compressSaveAsComicBookZip = AppSettings.defaultComicBookZip
            if let created = CompressionSupport.existingArchiveOutput(
                intended: archiveDestination,
                format: compressFormat,
                comicBookZip: comicBookZip
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([created])
            }
        } catch ArchiveError.cancelled {
            // Always remove partial output even if closeArchive bumped compressGeneration
            // (otherwise cancel-on-close leaves a half-written archive on disk).
            cleanupFailedCompression(
                archiveDestination: archiveDestination,
                sourceURLs: sourceURLs
            )
            guard generation == compressGeneration else { return }
            statusMessage = "Compression cancelled."
        } catch {
            cleanupFailedCompression(
                archiveDestination: archiveDestination,
                sourceURLs: sourceURLs
            )
            guard generation == compressGeneration else { return }
            CompressDiagnostics.log("compress failed: \(error.localizedDescription)")
            errorMessage = "\(error.localizedDescription)\n\nDiagnostics: \(CompressDiagnostics.logFilePath)"
            statusMessage = "Compression failed."
        }
    }

    private func cleanupFailedCompression(archiveDestination: URL, sourceURLs: [URL]) {
        // Do **not** delete `archiveDestination`. Every backend writes to a unique temp file and
        // only replaces the final path after success. Deleting the final path on error/cancel
        // destroyed existing archives the user had chosen to replace (e.g. Backup.zip).
        //
        // Temp work files are removed by each backend’s `defer { cleanupCompressionDestination }`.
        // We cannot know the random temp UUID from here, and must not invent a new one.
        _ = archiveDestination
        _ = sourceURLs
    }

    private func acquireSecurityScopedAccess(
        for urls: [URL],
        capturedTokens: [SecurityScopedAccess.Token] = []
    ) {
        releaseSecurityScopedAccess()
        if capturedTokens.isEmpty {
            archiveAccessTokens = SecurityScopedAccess.captureTokens(for: urls)
        } else {
            archiveAccessTokens = capturedTokens
        }
        SecurityScopedAccess.activate(archiveAccessTokens)
    }

    private func releaseSecurityScopedAccess() {
        SecurityScopedAccess.releaseAll(&archiveAccessTokens)
    }

    private func clearDragOutCache() {
        for handle in dragOutHandles.values {
            handle.cancel()
        }
        dragOutHandles.removeAll()
        for task in dragOutTasks.values {
            task.cancel()
        }
        dragOutTasks.removeAll()
        dragOutPrepared.removeAll()
    }

    func cleanupOnTermination() {
        loadTask?.cancel()
        loadHandle?.cancel()
        compressionHandle?.cancel()
        operationHandle?.cancel()
        clearDragOutCache()
        releaseSecurityScopedAccess()
        releaseCompressAccess()
        TempFileRegistry.cleanupAll()
    }

    private func chooseDestination(
        _ completion: @escaping (URL, [SecurityScopedAccess.Token]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "Choose where to extract archive contents."
        if let archiveURL {
            panel.directoryURL = archiveURL.deletingLastPathComponent()
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Capture scope/bookmark before the panel callback returns and before any async hop.
            let destination = url.standardizedFileURL
            let tokens = SecurityScopedAccess.captureTokens(for: [destination])
            completion(destination, tokens)
        }
    }
}

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    var previewURL: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as QLPreviewItem?
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        previewURL = nil
    }
}