import AppKit
import Carbon
import QuickLookUI
import SwiftUI

private enum AppWindowID {
    static let main = "main"
}

struct MainWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var browser: ArchiveBrowserModel?
    private weak var mainWindow: NSWindow?
    private var pendingOpenURL: URL?
    private var mainWindowCloseObserver: NSObjectProtocol?
    private var isReadyToQuitOnWindowClose = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep Launch Services UTI bindings (e.g. com.archivepeek.cbz) current so
        // document icons do not stick on an older ArchivePeek.app registration.
        DefaultAppRegistration.registerBundleWithLaunchServices()
        NSApp.servicesProvider = self
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        NSUpdateDynamicServices()
        FinderServices.applyPreference()
        DispatchQueue.main.async { [weak self] in
            self?.isReadyToQuitOnWindowClose = true
        }
    }

    @objc func extractHere(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        FinderServices.shared.extractHere(pboard, userData: userData, error: error)
    }

    @objc func createArchive(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        FinderServices.shared.createArchive(pboard, userData: userData, error: error)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        FinderServices.log("getURL \(string)")
        _ = FinderServices.shared.handleActionURL(url)
    }

    func setBrowser(_ browser: ArchiveBrowserModel) {
        self.browser = browser
        refreshWindowDropHandling()
        FinderServices.shared.onExtract = { [weak self] urls, tokens in
            self?.activateMainWindow()
            browser.handleFinderExtract(urls, tokens: tokens)
        }
        FinderServices.shared.onCreate = { [weak self] urls, tokens in
            self?.activateMainWindow()
            browser.handleFinderCreate(urls, tokens: tokens)
        }
        if let url = pendingOpenURL {
            pendingOpenURL = nil
            openArchive(url, in: browser)
        }
        drainPendingFinderActions(using: browser)
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingFinderActions(using: browser)
        }
    }

    private func drainPendingFinderActions(using browser: ArchiveBrowserModel) {
        if let pending = FinderServices.shared.takePendingExtract() {
            FinderServices.log("drain pending extract")
            activateMainWindow()
            browser.handleFinderExtract(pending.urls, tokens: pending.tokens)
        }
        if let pending = FinderServices.shared.takePendingCreate() {
            FinderServices.log("drain pending create")
            activateMainWindow()
            browser.handleFinderCreate(pending.urls, tokens: pending.tokens)
        }
    }

    func registerMainWindow(_ window: NSWindow) {
        if mainWindow == nil {
            mainWindow = window
            observeMainWindowClose(window)
        }
        refreshWindowDropHandling()
        WindowDropInstaller.install(on: window)
    }

    private func observeMainWindowClose(_ window: NSWindow) {
        if let mainWindowCloseObserver {
            NotificationCenter.default.removeObserver(mainWindowCloseObserver)
        }
        // WindowGroup often hides rather than destroys the last window, so
        // applicationShouldTerminateAfterLastWindowClosed may never fire.
        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.quitIfMainWindowClosed()
            }
        }
    }

    private func quitIfMainWindowClosed() {
        guard isReadyToQuitOnWindowClose else { return }
        browser?.cleanupOnTermination()
        NSApp.terminate(nil)
    }

    private func refreshWindowDropHandling() {
        guard let browser else { return }
        WindowDropInstaller.configure(
            onDrop: { [weak browser] urls in
                guard let browser, !browser.isCompressing else { return }
                browser.handleDroppedURLs(urls)
            },
            onTargetingChanged: { [weak browser] targeted in
                browser?.isDropTargeted = targeted
            }
        )
    }

    func handleExternalWindowValue(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AppWindowID.main else { return }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == FinderServices.urlScheme {
            FinderServices.log("WindowGroup action \(trimmed)")
            _ = FinderServices.shared.handleActionURL(url)
            return
        }
        if let fileURL = fileURL(fromExternalValue: trimmed) {
            FinderServices.log("WindowGroup file \(fileURL.path)")
            openFileFromFinder(fileURL)
        }
    }

    func openFileFromFinder(_ url: URL) {
        if url.scheme?.lowercased() == FinderServices.urlScheme {
            _ = FinderServices.shared.handleActionURL(url)
            return
        }
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        if let browser {
            openArchive(fileURL, in: browser)
        } else {
            pendingOpenURL = fileURL.standardizedFileURL
        }
    }

    private func fileURL(fromExternalValue value: String) -> URL? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        if value.hasPrefix("/") {
            let url = URL(fileURLWithPath: value)
            return FileManager.default.fileExists(atPath: url.path) ? url.standardizedFileURL : nil
        }
        return nil
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        FinderServices.log("application open \(urls.map(\.absoluteString).joined(separator: ", "))")
        var archives: [URL] = []
        for url in urls {
            if FinderServices.shared.handleActionURL(url) {
                continue
            }
            archives.append(url)
        }
        if let url = archives.first {
            openFileFromFinder(url)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            activateMainWindow()
        }
        return true
    }

    private func openArchive(_ url: URL, in browser: ArchiveBrowserModel) {
        activateMainWindow()
        // Capture scope/bookmark immediately while the system open grant is valid.
        let tokens = SecurityScopedAccess.captureTokens(for: [url.standardizedFileURL])
        browser.openArchive(url.standardizedFileURL, accessTokens: tokens)
        // Finder "open with" can still spawn an extra WindowGroup; close only then.
        scheduleDuplicateWindowCleanup()
    }

    private func scheduleDuplicateWindowCleanup() {
        for delay in [0.05, 0.15, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.closeDuplicateWindows()
                self?.activateMainWindow()
            }
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainApplicationWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func closeDuplicateWindows() {
        guard let keeper = mainWindow else { return }
        for window in duplicateApplicationWindows(keeping: keeper) {
            if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true {
                continue
            }
            window.close()
        }
        keeper.makeKeyAndOrderFront(nil)
    }

    private func duplicateApplicationWindows(keeping keeper: NSWindow) -> [NSWindow] {
        NSApp.windows.filter { window in
            window !== keeper &&
                window.isVisible &&
                !window.isSheet &&
                !(window is NSPanel) &&
                window.canBecomeMain &&
                window.level == .normal &&
                isLikelyArchivePeekContentWindow(window)
        }
    }

    private func isLikelyArchivePeekContentWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain &&
            window.level == .normal &&
            !window.isSheet &&
            !(window is NSPanel) &&
            window.styleMask.contains(.titled)
    }

    private var mainApplicationWindow: NSWindow? {
        mainWindow ?? NSApp.windows.first { isLikelyArchivePeekContentWindow($0) && !($0 is NSPanel) }
    }
}

@main
struct ArchivePeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var browser = ArchiveBrowserModel()

    init() {
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = QuickLookCoordinator.shared
            panel.delegate = QuickLookCoordinator.shared
        }
    }

    var body: some Scene {
        WindowGroup("ArchivePeek", id: AppWindowID.main) {
            ContentView()
                .environmentObject(browser)
                .frame(minWidth: 720, minHeight: 480)
                .background(MainWindowAccessor { appDelegate.registerMainWindow($0) })
                .onAppear {
                    appDelegate.setBrowser(browser)
                }
                .onOpenURL { url in
                    FinderServices.log("onOpenURL \(url.absoluteString)")
                    appDelegate.openFileFromFinder(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    browser.cleanupOnTermination()
                }
        }
        .handlesExternalEvents(matching: [AppWindowID.main])

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateChecker.checkAndPresent()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Compress…") {
                    browser.presentCompressSheet()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser.isCompressing || browser.isLoading)
                Button("Open Archive…") {
                    openArchivePanel()
                }
                .keyboardShortcut("o")
                .disabled(browser.isCompressing)
                Button("Close Archive") {
                    browser.closeArchive()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!browser.hasOpenArchive)
            }
            CommandGroup(replacing: .help) {
                Button("ArchivePeek Help") {
                    browser.showHelpSheet = true
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.checkAndPresent()
                }
                Button("ArchivePeek on GitHub") {
                    NSWorkspace.shared.open(AppInfo.githubRepositoryURL)
                }
                Divider()
                Button("7-Zip License") {
                    openSevenZipLicense()
                }
            }
        }
    }

    private func openSevenZipLicense() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Tools/7-Zip-LICENSE.txt"),
            Bundle.main.resourceURL?.appendingPathComponent("7-Zip-LICENSE.txt"),
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
    }

    private func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.message = "Choose an archive to open."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let standardized = url.standardizedFileURL
            let tokens = SecurityScopedAccess.captureTokens(for: [standardized])
            browser.openArchive(standardized, accessTokens: tokens)
        }
    }
}