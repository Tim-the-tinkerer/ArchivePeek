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
                        helpBullet("Open an archive with **Open** (⌘O), by double-clicking in Finder, or by dragging it onto the window. Split volumes (`.001`, `.z01`, `.part1.rar`) open as one archive.")
                        helpBullet("If ArchivePeek is already open, double-clicking an archive reuses the existing window.")
                        helpBullet("Use **Close Archive** (⇧⌘W) to return to the welcome screen without quitting.")
                        helpBullet("The red close button or **⌘W** quits ArchivePeek.")
                        helpBullet("Drop files or folders onto the window to add them to a new archive, or onto an open ZIP/7z archive to add them there.")
                        helpBullet("Double-click folders to navigate; double-click files to open them.")
                    }

                    helpSection("Browsing", icon: "folder") {
                        helpBullet("Use the breadcrumb bar to jump between folders inside the archive.")
                        helpBullet("Click to select files; Shift-click to select multiple items.")
                        helpBullet("Press Return to open the selected item, or **Space** to Quick Look.")
                        helpBullet("Right-click for Open, Quick Look, Extract, or Remove from Archive.")
                        helpBullet("Drag files out of the list to extract them to Finder.")
                        helpBullet("Press **Delete** to remove selected items from a ZIP or 7z archive.")
                    }

                    helpSection("Toolbar", icon: "menubar.rectangle") {
                        helpText("Toolbar buttons show icons only — hover any icon to see its name.")
                        helpBullet("**Open** and **Compress** are always available.")
                        helpBullet("**Close Archive** returns to the welcome screen when browsing an archive (it does not quit).")
                        helpBullet("The **Extract** menu contains Extract Selected, Extract All, and Extract All to Folder.")
                        helpBullet("**Add Files** and **Remove** edit ZIP and 7z archives.")
                        helpBullet("The open archive name appears in the status bar at the bottom of the window.")
                    }

                    helpSection("Extracting", icon: "square.and.arrow.down") {
                        helpBullet("Use the **Extract** menu for Extract Selected, Extract All, or Extract All to Folder.")
                        helpBullet("**Extract Selected** saves chosen files to a folder you pick.")
                        helpBullet("**Extract All** unpacks everything into the folder you choose.")
                        helpBullet("**Extract All to Folder** creates a folder named after the archive inside the location you choose, then unpacks into that folder.")
                        helpBullet("Individual file extraction is flat (no folder structure recreated).")
                        helpBullet("**Quick Look** (eye icon) previews a selected file without saving it permanently.")
                    }

                    helpSection("Split Archives", icon: "square.stack.3d.up") {
                        helpBullet("Keep every part in the same folder as the first volume.")
                        helpBullet("**7-Zip:** `Name.7z.001`, `Name.7z.002`, … — open any part; ArchivePeek uses `.001`.")
                        helpBullet("**ZIP:** `Name.zip` with `Name.z01`, or `Name.zip.001`, `Name.zip.002`, …")
                        helpBullet("**RAR:** `Name.part1.rar` / `Name.part2.rar`, or `Name.rar` with `Name.r00`.")
                        helpBullet("The status bar shows **Split 7z** (or ZIP/RAR) and the volume count.")
                        helpBullet("Extract, Quick Look, and Verify use the full set. Add and Remove are not available for split archives.")
                    }

                    helpSection("Editing Archives", icon: "pencil") {
                        helpBullet("ZIP (including CBZ) and 7z archives can be edited while open.")
                        helpBullet("**Add Files** (plus icon) or drop files/folders onto the window to add them to the current folder.")
                        helpBullet("**Remove** (trash icon), right-click **Remove from Archive**, or press **Delete** to remove selected items.")
                        helpBullet("Changes copy the archive, apply the edit, verify it, then replace the original only if that succeeds.")
                        helpBullet("RAR, TAR, DMG, ISO, split volumes, compressed TAR (`.tar.gz` and similar), and single-file GZIP/BZIP2/XZ archives cannot be modified — extract and create a new archive instead.")
                    }

                    helpSection("Compressing", icon: "doc.zipper") {
                        helpBullet("Choose **Compress** (⇧⌘N) or **Create Archive…** from the welcome screen.")
                        helpBullet("Supported output formats include ZIP, DMG, 7z, RAR, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, GZIP, BZIP2, and XZ.")
                        helpBullet("**Split into volumes** (ZIP, 7z, RAR) writes `Name.7z.001` / `Name.zip.001` or `Name.part1.rar`. Keep every part in the same folder.")
                        helpBullet("**RAR** creation requires WinRAR’s `rar` command (`brew install --cask rar` or rarlab.com). Opening RAR still works with bundled 7-Zip.")
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
                        helpBullet("ZIP, DMG, 7z, and RAR archives can be password-protected when creating an archive. RAR passwords also hide file names (header encryption).")
                        helpBullet("Opening an encrypted archive shows a password prompt immediately.")
                        helpBullet("7z password protection can also hide file names inside the archive.")
                        helpBullet("Enable **Solid archive** for 7z to improve compression on large groups of similar files. Solid archives are slower to create and slower to extract individual files from.")
                    }

                    helpSection("Settings", icon: "gearshape") {
                        helpBullet("Open **ArchivePeek → Settings…** (⌘,) to set default compression options.")
                        helpBullet("Defaults include format, compression level, verify before replace, solid 7z, comic book ZIP (.cbz), and DMG app installer layout.")
                        helpBullet("Defaults are applied each time you open the Compress sheet.")
                        helpBullet("Use **Set ArchivePeek as Default for Archives** to make ArchivePeek the default app for ZIP, 7z, TAR, RAR, and similar archives. DMG and ISO are excluded.")
                        helpBullet("Turn on **Show in Finder contextual menu**, then quit and reopen ArchivePeek. Right-click in Finder and look under **Services** or **Quick Actions** for **ArchivePeek: Extract Here** and **ArchivePeek: Create Archive** (Quick Actions may say **Extract Here** / **Create Archive**).")
                        helpBullet("**Extract Here** unpacks into a folder next to the archive. **Create Archive** uses your default format and saves next to the selected items. Encrypted archives prompt for a password, then continue.")
                        helpBullet("If the commands are missing, use **Open Keyboard Shortcuts…** in Settings and enable them under Services → Files and Folders.")
                    }

                    helpSection("Updates", icon: "arrow.down.circle") {
                        helpBullet("Choose **ArchivePeek → Check for Updates…** or **Help → Check for Updates…** to compare your version with the latest GitHub release.")
                        helpBullet("The project page is [github.com/Tim-the-tinkerer/ArchivePeek](https://github.com/Tim-the-tinkerer/ArchivePeek).")
                    }

                    helpSection("Drag & Drop", icon: "arrow.down.doc") {
                        helpBullet("Drop archives onto the window to open them.")
                        helpBullet("With no archive open, drop files or folders to add them to the compress list.")
                        helpBullet("With a ZIP or 7z archive open, drop files or folders to add them to the current folder.")
                        helpBullet("Drag files from the archive list to Finder to extract them.")
                    }

                    helpSection("Keyboard Shortcuts", icon: "keyboard") {
                        shortcutRow("⌘O", "Open archive")
                        shortcutRow("⌘W", "Quit (close window)")
                        shortcutRow("⇧⌘W", "Close archive")
                        shortcutRow("⇧⌘N", "Create archive")
                        shortcutRow("⌘,", "Settings")
                        shortcutRow("⌘?", "ArchivePeek Help")
                        shortcutRow("Return", "Open selected item")
                        shortcutRow("Delete", "Remove selected items from the archive")
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