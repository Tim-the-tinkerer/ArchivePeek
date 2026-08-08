# Changelog

All notable changes to ArchivePeek are documented in this file.

## [1.0.10] — 2026-08-08

### Fixed
- **Large Swift projects (e.g. DriveSense with a 200 MB+ `.build` tree)** — prepare now copies each source as a whole tree instead of walking file-by-file, which is faster and avoids hang/edge cases on packages and build caches.
- **7z progress no longer freezes** during solid/max compression — 7-Zip output is streamed so the UI shows files as they compress (level 9 + solid on large folders can take half a minute or more).
- Clearer diagnostics while staging and starting 7-Zip.

## [1.0.9] — 2026-08-08

### Fixed
- **Coding project archives keep what they need** — compression no longer treats project files as disposable.
- **`.gitignore` is kept** in ZIP, 7z, and TAR. It was incorrectly stripped as “junk” alongside `.DS_Store`.
- **7z no longer drops entire trees** such as `.git`, `.build`, `node_modules`, or `DerivedData`. Project backups and source archives are complete; delete regenerable folders yourself if you want a leaner archive.
- **Symlinks no longer hang prepare** — staging used to ask `isDirectory` / `isPackage` on every entry; those APIs follow symlink targets and can stall forever on dead mounts or DMG loops. Symlinks are detected first and recreated from link text only (never open the target).
- **Symlinks no longer wipe later folders** — do not call `skipDescendants()` after file symlinks (that dropped trees such as `.git`). Link targets are never walked.
- **Symlinks are preserved** in the archive as links (not resolved content).
- **Empty directories** are retained when staging for compression.
- **ZIP prepare path** — ZIP (including single-folder ditto) now stages files in-process first, same as 7z, so external volumes and permission-scoped folders do not produce incomplete archives.
- **Staging path corruption on macOS** — `/var` vs `/private/var` mismatches no longer mangle relative paths (which could nest files under truncated folder names and look like “missing” project content).

### Changed
- Only true macOS noise is excluded: `.DS_Store`, AppleDouble (`._*`), and `__MACOSX`.

## [1.0.8] — 2026-07-18

### Fixed
- **7z compression no longer drops application and help bundles** — staging previously used `skipsPackageDescendants` and only copied regular files, so nested `.app` and `.help` packages (and other macOS bundles) were omitted entirely. Projects such as Fractal Explorer and Tesseract Viewer lost their built apps and Help books. Packages are now copied as whole units.
- **7z staging keeps normal project files** while still omitting junk (`.DS_Store`, `._*`, `__MACOSX`), **`.gitignore`**, and known build folders (`.build`, `node_modules`, `.git`, `DerivedData`, `dist/.staging`). The previous “skip all hidden files” pass was too aggressive.
- Staging no longer treats every folder named `dist` as excluded — only `dist/.staging` is skipped, matching the documented behavior.

## [1.0.7] — 2026-07-13

### Fixed
- **Drag and drop into the window** — drops are handled at the window level so archives and files are accepted reliably across the welcome screen, file list, and empty areas.
- **Drag files and folders out to Finder** — manual drag sessions start from the file list; folders extract with their contents (or as empty folders); the window drop handler ignores outbound drags.
- **Quick Look (Space)** — Space is handled directly by the file list (archive entries must be extracted before preview); preview extraction stays off the main thread and the panel opens once the temp file is ready.

### Changed
- Dropped files capture security-scoped bookmarks immediately so archives outside the sandbox open correctly.

## [1.0.6] — 2026-07-12

### Added
- **Settings** (ArchivePeek → Settings…, ⌘,) with persistent compression defaults: format, level, verify after creation, solid 7z, and DMG app installer layout.
- **Set ArchivePeek as Default for Archives** — registers one exported archive type for all supported extensions (single macOS confirmation).

### Fixed
- Security-scoped file access no longer leaks permissions across compress, drop, and extract operations.
- Right-click **Quick Look** and **Extract** in the archive list work correctly.
- **Return** opens the selected item when the file list is focused.
- Canceling the password prompt or a failed archive open returns to the welcome screen instead of a blank browser.
- Compress cancel/failure releases folder access and cleans up partial archives.
- Saving an archive no longer silently deletes an existing file with the same name inside the source folder.
- Toolbar actions are disabled during load and compression to prevent overlapping work.
- Closing an archive or quitting cancels in-flight compression.
- Settings window no longer shows a scrollbar — sized to fit all options at once.
- **Set as Default** no longer claims DMG or ISO — disk images keep their usual system handlers; ArchivePeek can still open them when chosen manually.

### Changed
- **New app icon** — stacked archive with a magnifying lens, reflecting the “peek inside archives” concept.
- Welcome screen icon updated to match (`doc.text.magnifyingglass`).
- Compress sheet defaults come from Settings and reload each time you open Compress.
- Welcome screen stays visible under the compression progress overlay.
- `build-app.sh` regenerates the icon when `generate-icon.swift` changes.

## [1.0.5] — 2026-07-12

### Fixed
- **7z compression** now completes reliably for large folders and developer projects.
- 7-Zip helper is copied to Application Support before use — macOS no longer kills the bundled `7zz` inside the app bundle (exit code 9).
- 7z creation **prepares files in a temp folder** first (in-process, with your granted access) so the compressor never reads live folders that trigger extra permission prompts.
- **Symlinks are skipped** during prepare and stored safely by 7-Zip (`-snl`/`-snh`), fixing hangs on symlink loops (for example DMG staging trees) and links pointing outside the selection.
- **Build artifacts** (`.build`, `node_modules`, `.git`, `DerivedData`, `dist/.staging`) are omitted from 7z archives by default.
- Finished archives save correctly to the chosen location (move with copy fallback).
- Compression diagnostics log to `~/Library/Logs/ArchivePeek/compress.log` on failure.

### Changed
- 7z compress shows **Preparing… N files** progress while files are staged.
- Add Files prompt clarifies selecting everything in one step to minimize permission prompts.

## [1.0.4] — 2026-07-12

### Added
- **DMG** output format when creating archives (native `hdiutil`, with optional AES-256 encryption).
- **App installer layout** for DMG: adds an Applications folder shortcut when compressing `.app` bundles.

## [1.0.3] — 2026-07-12

### Fixed
- Opening an archive from Finder while ArchivePeek is already running no longer spawns a second window.
- Compression works again — the save dialog is no longer closed by duplicate-window cleanup.

## [1.0.2] — 2026-07-12

### Added
- **Verify integrity** after creating an archive (optional, on by default in the Compress sheet).
- **Verify Integrity** toolbar action to test the currently open archive for corruption.
- **Close Archive** (⇧⌘W) to return to the welcome screen without quitting the app.

### Changed
- Toolbar uses compact icon buttons and an **Extract** menu to save space.
- Open archive name shown in the status bar instead of the toolbar.

### Fixed
- `.DS_Store`, `._*`, and `__MACOSX` metadata no longer included when using the ditto ZIP fast path.
- Strengthened Mac metadata exclusions across ZIP, 7z, and TAR compression backends.

## [1.0.1] — 2026-07-12

### Security
- Block zip-slip path traversal in archive entries before extract, open, or preview.
- Remove unused password exposure via process environment variables.

### Added
- **Solid archive** option when creating 7z archives for better compression on large sets of similar files.
- **Password prompt** when opening encrypted ZIP and 7z archives.
- **In-app Help** (Help → ArchivePeek Help, ⌘?) with usage guide, shortcuts, and links to documentation.
- **README** and **CHANGELOG** bundled with the app.

### Changed
- Replaced the archive file list with a native table for faster selection, reliable double-click navigation, and smoother multi-select.
- After creating an archive, ArchivePeek reveals the file in Finder but no longer opens it automatically in the browser.
- Password-protected archives no longer hang on “Reading…”; the password sheet appears immediately.

### Fixed
- Race when switching archives or entering passwords while a load is in progress.
- TAR flat extraction now honors `preservePaths: false`.
- ZIP64 archives fall back to 7-Zip instead of failing native listing.
- Compression cancel cleans up temporary work files.
- Temp extract directories cleaned up on quit; preview temps replaced per session.
- Security-scoped access held for the active archive and extract destinations.
- Ditto fast path wired for single-item ZIP creation.
- Double-click to open folders and files inside archives.
- Shift-click and drag-to-Finder for archive contents.
- TAR path parsing for archives with spaces in names.
- ZIP creation argument order, exclusions (`.DS_Store`, `__MACOSX`), and zip-in-itself when saving inside the source folder.
- Compression speed for ZIP (native `zip` / `ditto` fast paths).
- Individual file extraction now saves flat to the chosen folder.
- Quick Look and context-menu extract/preview actions.

## [1.0.0] — 2026-07-12

### Added
- Initial release of ArchivePeek for macOS 13+.
- Browse ZIP, 7z, RAR, TAR, and many other archive formats without full extraction.
- Create archives in ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, GZIP, BZIP2, and XZ.
- Bundled 7-Zip 26.02 with native `zip`, `ditto`, and `bsdtar` backends.
- Compression progress with cancel support.
- Drag-and-drop to open archives, add compress sources, and extract files to Finder.
- Optional password protection for ZIP and 7z creation.
- Quick Look preview for files inside archives.