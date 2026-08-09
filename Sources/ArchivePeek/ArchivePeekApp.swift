import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep Launch Services UTI bindings (e.g. com.archivepeek.cbz) current so
        // document icons do not stick on an older ArchivePeek.app registration.
        DefaultAppRegistration.registerBundleWithLaunchServices()
    }

    func setBrowser(_ browser: ArchiveBrowserModel) {
        self.browser = browser
        refreshWindowDropHandling()
        if let url = pendingOpenURL {
            pendingOpenURL = nil
            openArchive(url, in: browser)
        }
    }

    func registerMainWindow(_ window: NSWindow) {
        if mainWindow == nil {
            mainWindow = window
        }
        refreshWindowDropHandling()
        WindowDropInstaller.install(on: window)
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let browser {
            openArchive(url, in: browser)
        } else {
            pendingOpenURL = url
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
        let title = window.title
        return title.isEmpty || title == "ArchivePeek"
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
        WindowGroup("ArchivePeek", id: AppWindowID.main, for: String.self) { _ in
            ContentView()
                .environmentObject(browser)
                .frame(minWidth: 720, minHeight: 480)
                .background(MainWindowAccessor { appDelegate.registerMainWindow($0) })
                .onAppear {
                    appDelegate.setBrowser(browser)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    browser.cleanupOnTermination()
                }
        } defaultValue: {
            AppWindowID.main
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))

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
                Button("Open Archive…") {
                    openArchivePanel()
                }
                .keyboardShortcut("o")
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