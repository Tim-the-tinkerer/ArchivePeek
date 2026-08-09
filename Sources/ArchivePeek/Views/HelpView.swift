import AppKit
import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    helpSection("Getting Started", icon: "sparkles") {
                        helpText("ArchivePeek lets you browse archive contents without extracting everything first, and create new archives from files and folders.")
                        helpBullet("Open an archive with **Open** (⌘O), by double-clicking in Finder, or by dragging it onto the window.")
                        helpBullet("If ArchivePeek is already open, double-clicking an archive reuses the existing window.")
                        helpBullet("Use **Close Archive** (⇧⌘W) to return to the welcome screen.")
                        helpBullet("Drop files or folders onto the window to add them to a new archive.")
                        helpBullet("Double-click folders to navigate; double-click files to open them.")
                    }

                    helpSection("Browsing", icon: "folder") {
                        helpBullet("Use the breadcrumb bar to jump between folders inside the archive.")
                        helpBullet("Click to select files; Shift-click to select multiple items.")
                        helpBullet("Press Return to open the selected item, or **Space** to Quick Look.")
                        helpBullet("Right-click for Open, Quick Look, or Extract.")
                        helpBullet("Drag files out of the list to extract them to Finder.")
                    }

                    helpSection("Toolbar", icon: "menubar.rectangle") {
                        helpText("Toolbar buttons show icons only — hover any icon to see its name.")
                        helpBullet("**Open** and **Compress** are always available.")
                        helpBullet("**Close Archive** returns to the welcome screen when browsing an archive.")
                        helpBullet("The **Extract** menu contains Extract Selected and Extract All.")
                        helpBullet("The open archive name appears in the status bar at the bottom of the window.")
                    }

                    helpSection("Extracting", icon: "square.and.arrow.down") {
                        helpBullet("Use the **Extract** menu for Extract Selected or Extract All.")
                        helpBullet("**Extract Selected** saves chosen files to a folder you pick.")
                        helpBullet("Individual file extraction is flat (no folder structure recreated).")
                        helpBullet("**Quick Look** (eye icon) previews a selected file without saving it permanently.")
                    }

                    helpSection("Compressing", icon: "doc.zipper") {
                        helpBullet("Choose **Compress** (⇧⌘N) or **Create Archive…** from the welcome screen.")
                        helpBullet("Supported output formats include ZIP, DMG, 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, GZIP, BZIP2, and XZ.")
                        helpBullet("Under **ZIP**, enable **Save as comic book ZIP** to write a standard ZIP with a `.cbz` extension for comic readers.")
                        helpBullet("**DMG** uses macOS hdiutil to create standard compressed or read-only disk images. DMG supports optional AES-256 encryption.")
                        helpBullet("When compressing a `.app` bundle to DMG, enable **App installer layout** to include an Applications folder shortcut for drag-to-install distribution.")
                        helpBullet("ZIP and **7z** prepare files first (with progress), then compress — reliable for large folders and developer projects on external volumes.")
                        helpBullet("Coding projects are archived **complete**: `.git`, `.gitignore`, `.build`, `node_modules`, hidden config (`.vscode`, `.env*`), and symlinks are kept (as links — targets are not followed, so dead mounts cannot hang prepare). Application and help bundles (`.app`, `.help`) are included in full.")
                        helpBullet("Save the archive **outside** the folder being compressed (for example, on Desktop).")
                        helpBullet("Prefer compressing the **project folder** as one item (not multi-selecting individual files) so nothing is left out.")
                        helpBullet("Add all files and folders in one step (one drag or one **Add Files** selection) to minimize macOS folder permission prompts.")
                        helpBullet("After creation, ArchivePeek reveals the new file in Finder but does not open it automatically.")
                        helpBullet("Enable **Verify before replacing** to integrity-test the new archive before replacing any file already at the destination.")
                        helpBullet("Use **Verify Integrity** in the toolbar to test the currently open archive.")
                        helpBullet("Only macOS junk is stripped: `.DS_Store`, AppleDouble (`._*`), and `__MACOSX`. Project files such as `.gitignore` are kept.")
                        helpBullet("If compression fails, open `~/Library/Logs/ArchivePeek/compress.log` for diagnostic details.")
                    }

                    helpSection("Passwords & 7z Options", icon: "lock.fill") {
                        helpBullet("ZIP, DMG, and 7z archives can be password-protected when creating an archive.")
                        helpBullet("Opening an encrypted archive shows a password prompt immediately.")
                        helpBullet("7z password protection can also hide file names inside the archive.")
                        helpBullet("Enable **Solid archive** for 7z to improve compression on large groups of similar files. Solid archives are slower to create and slower to extract individual files from.")
                    }

                    helpSection("Settings", icon: "gearshape") {
                        helpBullet("Open **ArchivePeek → Settings…** (⌘,) to set default compression options.")
                        helpBullet("Defaults include format, compression level, verify before replace, solid 7z, comic book ZIP (.cbz), and DMG app installer layout.")
                        helpBullet("Defaults are applied each time you open the Compress sheet.")
                        helpBullet("Use **Set ArchivePeek as Default for Archives** to make ArchivePeek the default app for ZIP, 7z, TAR, RAR, and similar archives. DMG and ISO are excluded.")
                    }

                    helpSection("Updates", icon: "arrow.down.circle") {
                        helpBullet("Choose **ArchivePeek → Check for Updates…** or **Help → Check for Updates…** to compare your version with the latest GitHub release.")
                        helpBullet("The project page is [github.com/Tim-the-tinkerer/ArchivePeek](https://github.com/Tim-the-tinkerer/ArchivePeek).")
                    }

                    helpSection("Drag & Drop", icon: "arrow.down.doc") {
                        helpBullet("Drop archives onto the window to open them.")
                        helpBullet("Drop files or folders to add them to the compress list.")
                        helpBullet("Drag files from the archive list to Finder to extract them.")
                    }

                    helpSection("Keyboard Shortcuts", icon: "keyboard") {
                        shortcutRow("⌘O", "Open archive")
                        shortcutRow("⇧⌘W", "Close archive")
                        shortcutRow("⇧⌘N", "Create archive")
                        shortcutRow("⌘,", "Settings")
                        shortcutRow("⌘?", "ArchivePeek Help")
                        shortcutRow("Return", "Open selected item")
                    }

                    helpSection("Tools", icon: "wrench.and.screwdriver") {
                        helpText("ArchivePeek bundles 7-Zip 26.02 and uses macOS tools where they are faster: zip, ditto, and bsdtar.")
                        helpText(ToolLocator.statusSummary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text("ArchivePeek Help")
                    .font(.title2.bold())
                Text("Version \(AppInfo.versionLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open Changelog") { openBundledResource(named: "CHANGELOG.md") }
            Button("Open README") { openBundledResource(named: "README.md") }
            Button("GitHub") { NSWorkspace.shared.open(AppInfo.githubRepositoryURL) }
            Button("Check for Updates…") { UpdateChecker.checkAndPresent() }
            Button("7-Zip License") { openBundledResource(named: "Tools/7-Zip-LICENSE.txt", fallback: "7-Zip-LICENSE.txt") }
            Spacer()
        }
        .padding(16)
    }

    private func helpSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func helpBullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Text(action)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func openBundledResource(named name: String, fallback: String? = nil) {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            fallback.flatMap { Bundle.main.resourceURL?.appendingPathComponent($0) },
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
    }
}