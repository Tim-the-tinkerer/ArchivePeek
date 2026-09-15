import AppKit

/// Finder Services and Quick Actions for one-click extract and create.
final class FinderServices: NSObject {
    static let shared = FinderServices()

    static let extractMenuTitle = "ArchivePeek: Extract Here"
    static let createMenuTitle = "ArchivePeek: Create Archive"
    static let extractMessage = "extractHere"
    static let createMessage = "createArchive"
    static let urlScheme = "archivepeek"

    var onExtract: (([URL], [SecurityScopedAccess.Token]) -> Void)?
    var onCreate: (([URL], [SecurityScopedAccess.Token]) -> Void)?

    private var pendingExtract: (urls: [URL], tokens: [SecurityScopedAccess.Token])?
    private var pendingCreate: (urls: [URL], tokens: [SecurityScopedAccess.Token])?

    var hasPendingWork: Bool {
        pendingExtract != nil || pendingCreate != nil
    }

    func takePendingExtract() -> (urls: [URL], tokens: [SecurityScopedAccess.Token])? {
        let value = pendingExtract
        pendingExtract = nil
        return value
    }

    func takePendingCreate() -> (urls: [URL], tokens: [SecurityScopedAccess.Token])? {
        let value = pendingCreate
        pendingCreate = nil
        return value
    }

    @objc(extractHere:userData:error:)
    func extractHere(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let urls = Self.fileURLs(from: pboard)
        Self.log("extractHere pasteboard types=\(pboard.types ?? []) urls=\(urls.map(\.path))")
        let tokens = SecurityScopedAccess.captureTokens(for: urls)
        dispatch(urls: urls, tokens: tokens, create: false)
    }

    @objc(createArchive:userData:error:)
    func createArchive(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let urls = Self.fileURLs(from: pboard)
        Self.log("createArchive pasteboard types=\(pboard.types ?? []) urls=\(urls.map(\.path))")
        let tokens = SecurityScopedAccess.captureTokens(for: urls)
        dispatch(urls: urls, tokens: tokens, create: true)
    }

    func handleActionURL(_ url: URL) -> Bool {
        Self.log("handleActionURL \(url.absoluteString)")
        guard url.scheme?.lowercased() == Self.urlScheme else { return false }
        let files = Self.paths(fromActionURL: url)
        Self.log("parsed \(files.count) path(s): \(files.map(\.path).joined(separator: ", "))")
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let tokens = SecurityScopedAccess.captureTokens(for: files)
        if host.hasPrefix("extract") {
            dispatch(urls: files, tokens: tokens, create: false)
            return true
        }
        if host.hasPrefix("create") {
            dispatch(urls: files, tokens: tokens, create: true)
            return true
        }
        Self.log("unknown host/path \(host)")
        return false
    }

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        NSLog("ArchivePeek Finder: %@", message)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ArchivePeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("finder.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: file.path) {
                if let handle = try? FileHandle(forWritingTo: file) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: file)
            }
        }
    }

    private func dispatch(
        urls: [URL],
        tokens: [SecurityScopedAccess.Token],
        create: Bool
    ) {
        let run = { [weak self] in
            self?.deliver(urls: urls, tokens: tokens, create: create, attempt: 0)
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async { run() }
        }
    }

    private func deliver(
        urls: [URL],
        tokens: [SecurityScopedAccess.Token],
        create: Bool,
        attempt: Int
    ) {
        NSApp.activate(ignoringOtherApps: true)
        if create {
            if let handler = onCreate {
                Self.log("dispatch create → handler (\(urls.count) urls)")
                handler(urls, tokens)
                return
            }
        } else if let handler = onExtract {
            Self.log("dispatch extract → handler (\(urls.count) urls)")
            handler(urls, tokens)
            return
        }
        if attempt < 50 {
            Self.log("browser not ready, retry \(attempt + 1)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.deliver(urls: urls, tokens: tokens, create: create, attempt: attempt + 1)
            }
        } else if create {
            Self.log("dispatch create → pending after retries")
            pendingCreate = (urls, tokens)
        } else {
            Self.log("dispatch extract → pending after retries")
            pendingExtract = (urls, tokens)
        }
    }

    static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        if let paths = pboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        if let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map { $0.standardizedFileURL }
        }
        if let items = pboard.pasteboardItems {
            var urls: [URL] = []
            for item in items {
                if let raw = item.string(forType: .fileURL) {
                    let url = URL(string: raw) ?? URL(fileURLWithPath: raw)
                    urls.append((url.isFileURL ? url : URL(fileURLWithPath: raw)).standardizedFileURL)
                }
            }
            if !urls.isEmpty { return urls }
        }
        return []
    }

    static func paths(fromActionURL url: URL) -> [URL] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }
        let items = components.queryItems ?? []
        return items.compactMap { item in
            guard item.name == "path", let value = item.value, !value.isEmpty else { return nil }
            if value.hasPrefix("file:") {
                return URL(string: value)?.standardizedFileURL
            }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
    }

    static func applyPreference() {
        setContextMenuEnabled(AppSettings.finderContextMenuEnabled)
    }

    static func setContextMenuEnabled(_ enabled: Bool) {
        AppSettings.finderContextMenuEnabled = enabled
        writePasteboardServiceStatus(enabled: enabled)
        NSUpdateDynamicServices()
        flushPasteboardServer()
        if enabled {
            installQuickActions()
        } else {
            removeQuickActions()
        }
        DefaultAppRegistration.registerBundleWithLaunchServices()
    }

    private static func writePasteboardServiceStatus(enabled: Bool) {
        let defaults = UserDefaults(suiteName: "pbs")
        var status = defaults?.dictionary(forKey: "NSServicesStatus") ?? [:]
        let payload: [String: Any] = [
            "enabled_context_menu": enabled,
            "enabled_services_menu": enabled,
        ]
        for key in serviceStatusKeys() {
            status[key] = payload
        }
        defaults?.set(status, forKey: "NSServicesStatus")
        defaults?.synchronize()
    }

    private static func serviceStatusKeys() -> [String] {
        let bundle = Bundle.main.bundleIdentifier ?? "com.archivepeek.app"
        let pairs = [
            (extractMenuTitle, extractMessage),
            (createMenuTitle, createMessage),
            ("Extract Here", extractMessage),
            ("Create Archive", createMessage),
        ]
        var keys: [String] = []
        for (menu, message) in pairs {
            keys.append("\(bundle) - \(menu) - \(message)")
            keys.append("(null) - \(menu) - \(message)")
            keys.append("\(bundle) - ArchivePeek/\(menu) - \(message)")
        }
        return keys
    }

    private static func flushPasteboardServer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        process.arguments = ["-flush"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let flushDefs = Process()
        flushDefs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        flushDefs.arguments = ["-flush_userdefs"]
        flushDefs.standardOutput = FileHandle.nullDevice
        flushDefs.standardError = FileHandle.nullDevice
        try? flushDefs.run()
        flushDefs.waitUntilExit()
    }

    private static var servicesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
    }

    private static let extractWorkflowName = "ArchivePeek Extract Here.workflow"
    private static let createWorkflowName = "ArchivePeek Create Archive.workflow"

    private static func installQuickActions() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: servicesDirectory, withIntermediateDirectories: true)
        installWorkflow(
            named: extractWorkflowName,
            menuTitle: "Extract Here",
            host: "extract"
        )
        installWorkflow(
            named: createWorkflowName,
            menuTitle: "Create Archive",
            host: "create"
        )
        NSUpdateDynamicServices()
        flushPasteboardServer()
    }

    private static func removeQuickActions() {
        let fileManager = FileManager.default
        for name in [extractWorkflowName, createWorkflowName] {
            let url = servicesDirectory.appendingPathComponent(name)
            try? fileManager.removeItem(at: url)
        }
        NSUpdateDynamicServices()
        flushPasteboardServer()
    }

    private static func installWorkflow(named name: String, menuTitle: String, host: String) {
        let root = servicesDirectory.appendingPathComponent(name, isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>NSServices</key>
            <array>
                <dict>
                    <key>NSBackgroundColorName</key>
                    <string>background</string>
                    <key>NSIconName</key>
                    <string>NSActionTemplate</string>
                    <key>NSMenuItem</key>
                    <dict>
                        <key>default</key>
                        <string>\(menuTitle)</string>
                    </dict>
                    <key>NSMessage</key>
                    <string>runWorkflowAsService</string>
                    <key>NSSendFileTypes</key>
                    <array>
                        <string>public.item</string>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
        try? info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try? completeWorkflowDocument(host: host).write(
            to: contents.appendingPathComponent("document.wflow"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func completeWorkflowDocument(host: String) -> String {
        let uuid1 = UUID().uuidString
        let uuid2 = UUID().uuidString
        let uuid3 = UUID().uuidString
        // Encode paths with JXA (same approach as working Finder services), then open our URL scheme.
        let script = """
        q=""
        for f in "${@:1:64}"; do
          u=$(V="$f" osascript -l JavaScript -e 'ObjC.import("stdlib"); function run(){return encodeURIComponent($.getenv("V"))}')
          q="$q&path=$u"
        done
        open "archivepeek://\(host)?${q#&}"
        """
        let escaped = script
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>AMApplicationBuild</key>
        	<string>534</string>
        	<key>AMApplicationVersion</key>
        	<string>2.10</string>
        	<key>AMDocumentVersion</key>
        	<string>2</string>
        	<key>actions</key>
        	<array>
        		<dict>
        			<key>action</key>
        			<dict>
        				<key>AMAccepts</key>
        				<dict>
        					<key>Container</key>
        					<string>List</string>
        					<key>Optional</key>
        					<true/>
        					<key>Types</key>
        					<array>
        						<string>com.apple.cocoa.path</string>
        					</array>
        				</dict>
        				<key>AMActionVersion</key>
        				<string>2.0.3</string>
        				<key>AMApplication</key>
        				<array>
        					<string>Automator</string>
        				</array>
        				<key>AMParameterProperties</key>
        				<dict>
        					<key>COMMAND_STRING</key>
        					<dict/>
        					<key>CheckedForUserDefaultShell</key>
        					<dict/>
        					<key>inputMethod</key>
        					<dict/>
        					<key>shell</key>
        					<dict/>
        					<key>source</key>
        					<dict/>
        				</dict>
        				<key>AMProvides</key>
        				<dict>
        					<key>Container</key>
        					<string>List</string>
        					<key>Types</key>
        					<array>
        						<string>com.apple.cocoa.string</string>
        					</array>
        				</dict>
        				<key>ActionBundlePath</key>
        				<string>/System/Library/Automator/Run Shell Script.action</string>
        				<key>ActionName</key>
        				<string>Run Shell Script</string>
        				<key>ActionParameters</key>
        				<dict>
        					<key>COMMAND_STRING</key>
        					<string>\(escaped)</string>
        					<key>CheckedForUserDefaultShell</key>
        					<true/>
        					<key>inputMethod</key>
        					<integer>1</integer>
        					<key>shell</key>
        					<string>/bin/zsh</string>
        					<key>source</key>
        					<string></string>
        				</dict>
        				<key>BundleIdentifier</key>
        				<string>com.apple.RunShellScript</string>
        				<key>CFBundleVersion</key>
        				<string>2.0.3</string>
        				<key>CanShowSelectedItemsWhenRun</key>
        				<false/>
        				<key>CanShowWhenRun</key>
        				<true/>
        				<key>Category</key>
        				<array>
        					<string>AMCategoryUtilities</string>
        				</array>
        				<key>Class Name</key>
        				<string>RunShellScriptAction</string>
        				<key>InputUUID</key>
        				<string>\(uuid1)</string>
        				<key>Keywords</key>
        				<array>
        					<string>Shell</string>
        				</array>
        				<key>OutputUUID</key>
        				<string>\(uuid2)</string>
        				<key>UUID</key>
        				<string>\(uuid3)</string>
        				<key>UnlocalizedApplications</key>
        				<array>
        					<string>Automator</string>
        				</array>
        				<key>arguments</key>
        				<dict>
        					<key>0</key>
        					<dict>
        						<key>default value</key>
        						<integer>0</integer>
        						<key>name</key>
        						<string>inputMethod</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>0</string>
        					</dict>
        					<key>1</key>
        					<dict>
        						<key>default value</key>
        						<false/>
        						<key>name</key>
        						<string>CheckedForUserDefaultShell</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>1</string>
        					</dict>
        					<key>2</key>
        					<dict>
        						<key>default value</key>
        						<string></string>
        						<key>name</key>
        						<string>source</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>2</string>
        					</dict>
        					<key>3</key>
        					<dict>
        						<key>default value</key>
        						<string></string>
        						<key>name</key>
        						<string>COMMAND_STRING</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>3</string>
        					</dict>
        					<key>4</key>
        					<dict>
        						<key>default value</key>
        						<string>/bin/zsh</string>
        						<key>name</key>
        						<string>shell</string>
        						<key>required</key>
        						<string>0</string>
        						<key>type</key>
        						<string>0</string>
        						<key>uuid</key>
        						<string>4</string>
        					</dict>
        				</dict>
        				<key>isViewVisible</key>
        				<integer>1</integer>
        				<key>nibPath</key>
        				<string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
        			</dict>
        			<key>isViewVisible</key>
        			<integer>1</integer>
        		</dict>
        	</array>
        	<key>connectors</key>
        	<dict/>
        	<key>workflowMetaData</key>
        	<dict>
        		<key>applicationBundleID</key>
        		<string>com.apple.finder</string>
        		<key>applicationPath</key>
        		<string>/System/Library/CoreServices/Finder.app</string>
        		<key>inputTypeIdentifier</key>
        		<string>com.apple.Automator.fileSystemObject</string>
        		<key>outputTypeIdentifier</key>
        		<string>com.apple.Automator.nothing</string>
        		<key>presentationMode</key>
        		<integer>15</integer>
        		<key>processesInput</key>
        		<integer>0</integer>
        		<key>serviceApplicationBundleID</key>
        		<string>com.apple.finder</string>
        		<key>serviceApplicationPath</key>
        		<string>/System/Library/CoreServices/Finder.app</string>
        		<key>serviceInputTypeIdentifier</key>
        		<string>com.apple.Automator.fileSystemObject</string>
        		<key>serviceOutputTypeIdentifier</key>
        		<string>com.apple.Automator.nothing</string>
        		<key>systemImageName</key>
        		<string>NSActionTemplate</string>
        		<key>workflowTypeIdentifier</key>
        		<string>com.apple.Automator.servicesMenu</string>
        	</dict>
        </dict>
        </plist>
        """
    }
}
