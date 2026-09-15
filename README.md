# ArchivePeek

A native macOS app for browsing archive contents without extracting everything first, and for creating new archives quickly.

**Version 1.0.33** · macOS 13.0 or later

**Source & updates:** [github.com/Tim-the-tinkerer/ArchivePeek](https://github.com/Tim-the-tinkerer/ArchivePeek) — use **ArchivePeek → Check for Updates…** in the app.

## Features

- **Browse** ZIP, 7z, RAR, TAR, GZ, BZ2, XZ, split volumes (`.001`, `.z01`, `.part1.rar`), and many other formats
- **Extract** selected files, individual items, or entire archives — including **Extract All to Folder**
- **Add and remove** files in open ZIP and 7z archives
- **Compress** files and folders into ZIP, DMG, 7z, RAR, TAR, and more — including **split volumes**
- **Comic book ZIP (CBZ)** — optional `.cbz` extension under the ZIP format for comic readers
- **Verify integrity** of created or open archives
- **Quick Look** files inside archives
- **Drag and drop** to open, compress, add files to an open archive, and pull files out to Finder
- **Password-protected** ZIP, DMG, 7z, and RAR archives (create and open)
- **DMG app installer layout** — optional Applications folder shortcut when distributing `.app` bundles
- **Solid 7z** option for stronger compression on large file sets
- **Fast paths** using native macOS `zip`, `ditto`, and `bsdtar` where possible
- **Clean archives** — excludes only macOS junk (`.DS_Store`, AppleDouble `._*`, `__MACOSX`); keeps `.gitignore`, `.git`, and other project files
- **Settings** — default compression format, level, verify-after-create, comic book ZIP, Finder contextual menu (Extract Here / Create Archive), and optional “make default app” for archives

## Getting Started

### Run the app

1. Build the app bundle:
   ```bash
   ./build-app.sh
   ```
2. Open `ArchivePeek.app`.

Or double-click `Build ArchivePeek.command` in Finder.

### Basic usage

| Action | How |
|--------|-----|
| Open an archive | **Open** (⌘O), double-click in Finder, or drag onto the window (reuses the existing window if ArchivePeek is already open). For split sets, open any part — ArchivePeek uses the first volume |
| Close archive | **Close Archive** (⇧⌘W) or File → Close Archive — returns to the welcome screen |
| Quit | Red close button or ⌘W — quits ArchivePeek (does not leave it in the Dock) |
| Browse folders | Double-click folders in the list |
| Open a file | Double-click, or select and press Return |
| Extract | **Extract** menu in the toolbar, or right-click context menu |
| Extract all to folder | **Extract → Extract All to Folder…** — creates a folder named after the archive |
| Add files | Plus icon, or drop files onto an open ZIP/7z archive |
| Remove files | Trash icon, right-click **Remove from Archive**, or Delete |
| Verify archive | Shield icon in the toolbar (hover icons for labels) |
| Create archive | **Compress** (⇧⌘N) or drag files/folders onto the window |
| Settings | **ArchivePeek → Settings…** (⌘,) |
| Finder Extract Here | Settings → **Show in Finder contextual menu**, then right-click an archive → **Services** or **Quick Actions** → **ArchivePeek: Extract Here** (or **Extract Here**) |
| Finder Create Archive | Same setting, then right-click files or folders → **ArchivePeek: Create Archive** (or **Create Archive**) |
| Help | **Help → ArchivePeek Help** (⌘?) |

Toolbar buttons are icon-only — hover any icon to see its name.

## Settings

Open **ArchivePeek → Settings…** (⌘,) to set defaults applied whenever you open the Compress sheet:

- Default archive format and compression level
- Verify before replacing an existing destination file (on/off)
- Solid 7z archive (on/off)
- Save ZIP as comic book (`.cbz`) (on/off, when default format is ZIP)
- DMG app installer layout (on/off)

Use **Set ArchivePeek as Default for Archives** to register ArchivePeek as the system default for ZIP, 7z, TAR, RAR, and similar archives. DMG and ISO are excluded (Disk Utility or Finder remain the usual handlers). macOS asks for a single confirmation.

Turn on **Show in Finder contextual menu** for one-click **Extract Here** and **Create Archive**. After enabling, quit and reopen ArchivePeek, then right-click in Finder. macOS usually lists the commands under **Services** or **Quick Actions**. Extract unpacks into a folder next to the archive. Create uses your default format and saves next to the selection. If the items are missing, Settings → **Open Keyboard Shortcuts…** → Services → Files and Folders.

## Compression notes

- **ZIP** without a password uses the fast native compressor (`zip` or `ditto` for single folders). Enable **Save as comic book ZIP** to write the same archive with a `.cbz` extension.
- **Split into volumes** (ZIP, 7z, RAR) writes numbered parts (`Name.7z.001`, `Name.part1.rar`) so a set can be copied across size-limited media. Keep every part in the same folder.
- **RAR** creation needs WinRAR’s `rar` command (`brew install --cask rar` or [rarlab.com](https://www.rarlab.com/)). Opening and extracting RAR uses bundled 7-Zip and does not need `rar`.
- **DMG** uses macOS `hdiutil` for standard compressed disk images (optional AES-256 encryption). When archiving a `.app`, enable **App installer layout** to add an Applications folder shortcut.
- **ZIP and 7z** prepare files in a temp folder first (with progress), then compress — this avoids macOS permission prompts and incomplete reads on external volumes or large developer trees.
- **Coding projects stay complete** — `.git`, `.gitignore`, `.build`, `node_modules`, hidden config, and symlinks are included. Application and help bundles (`.app`, `.help`) are copied as whole packages.
- Prefer archiving the **project folder** as a single item rather than multi-selecting files (multi-select only includes what you pick).
- **ZIP or 7z with a password** uses 7-Zip and encrypts archive contents.
- **7z solid archives** improve compression for many similar files but are slower to create and to extract individual files from.
- **Verify before replacing** integrity-tests the new archive before replacing any file already at the destination (enabled by default).
- Save new archives **outside** the folder being compressed (for example, on Desktop) to avoid nesting the archive inside itself.
- Add all items in **one** Add Files step or drag to minimize folder permission prompts.
- Only Mac metadata (`.DS_Store`, `._*`, `__MACOSX`) is excluded automatically — not project source files.
- If compression fails, see `~/Library/Logs/ArchivePeek/compress.log` for details.

## Editing open archives

ZIP (including CBZ) and 7z archives can be changed while they are open:

- **Add Files** (plus icon) or drop files/folders onto the window to add them to the folder you are viewing. Existing names prompt before replace.
- **Remove** (trash icon), right-click **Remove from Archive**, or press **Delete**. ArchivePeek confirms first.
- The original file is copied, edited, verified, then replaced only if that succeeds. Cancel or failure leaves the original archive in place.
- RAR, TAR (including `.tar.gz` / `.tar.bz2` / `.tar.xz`), DMG, ISO, split volumes, and single-file GZIP/BZIP2/XZ cannot be modified — extract and create a new archive instead.

## Split archives

Keep every volume in the same folder. ArchivePeek opens the first volume even if you chose `.002`, `.z01`, or `.part3.rar`.

Create split ZIP/7z/RAR from the Compress sheet (**Split into volumes**).

- **7-Zip:** `Name.7z.001`, `Name.7z.002`, …
- **ZIP:** `Name.zip` plus `Name.z01`, `Name.z02`, … or `Name.zip.001`, `Name.zip.002`, …
- **RAR:** `Name.part1.rar`, `Name.part2.rar`, … or `Name.rar` plus `Name.r00`, `Name.r01`, …

A missing first volume is reported instead of opening a later part alone. Extract, Quick Look, and Verify work on the whole set. Add/Remove are disabled.

## Building from source

Requirements:

- macOS 13+
- **Xcode** (the full app). Command Line Tools alone cannot compile SwiftUI macros (`@State`). `build-app.sh` and **Build ArchivePeek.command** use `/Applications/Xcode.app` even if `xcode-select` points at Command Line Tools.

```bash
# Debug build
swift build

# Release app bundle (downloads and bundles 7-Zip on first run)
./build-app.sh

# Release build without launching
./build-app.sh --no-launch

# Clean rebuild
./build-app.sh --clean

# Run automated test checklist
./run-manual-checklist.sh
```

## Project layout

```
ArchivePeek/
├── Sources/ArchivePeek/     Swift source
├── AppInfo.plist            App metadata and version
├── build-app.sh             Assembles ArchivePeek.app
├── select-xcode-toolchain.sh  Prefers full Xcode over Command Line Tools
├── generate-icon.swift      Renders AppIcon.icns (stacked archive + magnifying lens)
├── vendor-tools.sh          Bundles 7-Zip into the app
├── run-manual-checklist.sh  Automated smoke tests
├── CHANGELOG.md
└── README.md
```

## Third-party components

ArchivePeek bundles [7-Zip](https://www.7-zip.org/) 26.02 (LGPL). See `ThirdParty/7-Zip-LICENSE.txt` or **Help → 7-Zip License** in the app.

System tools used when available:

- `/usr/bin/zip`
- `/usr/bin/ditto`
- `/usr/bin/tar` (bsdtar)
- `/usr/bin/unzip`
- `/usr/bin/hdiutil` (DMG creation)

## Changelog

See [CHANGELOG.md](CHANGELOG.md).