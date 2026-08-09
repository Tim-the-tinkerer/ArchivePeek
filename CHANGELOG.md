# Changelog

All notable changes to ArchivePeek are documented in this file.

## [1.0.26] — 2026-08-09

### Added
- **Check for Updates** — **ArchivePeek → Check for Updates…**, **Help → Check for Updates…**, Settings, and Help compare your version with the latest GitHub release and open [github.com/Tim-the-tinkerer/ArchivePeek](https://github.com/Tim-the-tinkerer/ArchivePeek) (or Releases) when appropriate.
- **Help → ArchivePeek on GitHub** opens the project repository.

## [1.0.25] — 2026-08-09

### Fixed
- **CBZ icons still wrong after 1.0.24** — Launch Services was still using a stale `/Applications/ArchivePeek.app` (1.0.22) that mapped `.cbz` to the generic archive type. `build-app.sh` now installs into `/Applications` and re-registers the app; ArchivePeek also re-registers its UTIs on launch. Correct presentation is the standard zipper document with a **CBZ** label (not ComicReader’s comic-book badge and not an unrelated coffee-cup graphic).

## [1.0.24] — 2026-08-09

### Fixed
- **CBZ Finder type** — comic book ZIP uses a dedicated type (`com.archivepeek.cbz`) that conforms to `public.zip-archive`, instead of the generic archive type.

## [1.0.23] — 2026-08-09

### Added
- **Comic book ZIP (CBZ)** — under the ZIP format, enable **Save as comic book ZIP** to create a standard ZIP archive with a `.cbz` extension for comic readers. Password, compression level, and verify options work the same as ZIP. Default is available in Settings when ZIP is the default format.

## [1.0.22] — 2026-08-08

### Fixed
- **Atomic destination commit** — after building in system temp, the archive is staged as a unique sibling of the final path (`.ArchivePeek-<uuid>.zip` etc.) **without** touching the existing final file, then committed with `replaceItemAt` / move. If staging or commit fails, only temps are removed; a pre-existing destination survives.
- **Verify before replace** — “Verify after compress” now integrity-tests the staged sibling **before** atomic commit. A failed verify leaves any existing archive at the destination intact.

## [1.0.21] — 2026-08-08

### Fixed
- **Failed compress no longer deletes an existing archive** — every format (ZIP, 7z, TAR, DMG, ditto) always writes to a unique temporary file and replaces the final path only after success. Error/cancel cleanup must not delete the destination the user was replacing (e.g. existing `Backup.zip`).
- **Case-insensitive staging name collisions** — `Foo` and `foo` are treated as the same top-level name on typical macOS volumes, matching how the staging directory actually collides.
- **ProcessRunner Swift 6 readiness** — pipe EOF completion uses a Sendable one-shot flag instead of nested non-Sendable local functions (avoids Swift 6.2 concurrent-closure warnings).

### Notes
- Cancel during prepare still polls **between** top-level sources; a single whole-tree `copyItem` of a very large folder is not mid-copy interruptible (intentional trade-off for correctness/performance of whole-tree staging).

## [1.0.20] — 2026-08-08

### Fixed
- **Partial archives after cancel-on-close** — cancel/error cleanup always removes half-written output even when `closeArchive` bumps `compressGeneration` (previously those cleanups were skipped).
- **Post-compress verify is cancellable** — integrity check after create uses the compress cancel handle, so close/stop does not leave a verify process running.
- **Table no longer steals keyboard focus** — the file list becomes first responder only when its contents change, not on every SwiftUI refresh.
- **Control characters in archive paths** — reject CR/LF/TAB and other C0 controls in entry path components (in addition to wildcards and `..`).

## [1.0.19] — 2026-08-08

### Fixed
- **List/reload cancel stops listing tools** — opening or closing an archive cancels the in-flight 7-Zip/bsdtar list process (not only the Swift task).
- **Preview cancel** — Quick Look extract uses the shared operation handle and is terminated on close/switch archive.
- **Drag-out cancel** — prepare-drag and file-promise extracts keep per-entry handles that are cancelled when the drag cache is cleared (close/switch/quit).
- **Common parent path for compress** — resolves symlink roots before computing the shared working directory (pairs with relative path matching).

## [1.0.18] — 2026-08-08

### Fixed
- **Archive path wildcards blocked** — entry paths containing `*`, `?`, or `[` are rejected so 7-Zip/unzip cannot expand them during extract.
- **Close / switch archive cancels extract & verify** — in-flight extract, open, and verify subprocesses are terminated via a shared operation handle (no orphaned tools after close).
- **Drag-out main-thread wait shortened** — prepared-URL wait reduced from 3s to 0.35s so slow extracts fall through to file promises without freezing the UI.

## [1.0.17] — 2026-08-08

### Fixed
- **Incomplete ZIP listings no longer under-validate Extract All** — undecodable central-directory names and short parses escalate to 7-Zip instead of silently omitting members from path safety checks.
- **Lossy ZIP name fallback** — remaining undecodable names use UTF-8 lossy decoding so entries stay listed when possible.
- **7-Zip Extract All creates the destination folder** — matches tar/unzip behavior when the target directory is missing.
- **Directory readability checks** — folder sources accept search (`x`) permission; plain symlinks are not rejected for unreadable targets.
- **Relative compress paths** — path prefix matching resolves symlink roots (`/var` vs `/private/var`) before computing relatives.
- **Open archive clears stale listing/drag cache** — switching archives no longer leaves the previous listing or drag-out temps associated with the new open.

## [1.0.16] — 2026-08-08

### Fixed
- **7z archives no longer store temp absolute paths** — after staging, 7-Zip is invoked with relative basenames (cwd = staging parent), so archives open with top-level project folders instead of `private/var/folders/…/ArchivePeek-input-…/…`.
- **Security-scope activate no longer hard-fails** — compress, verify, preview, and drag-out still try to activate scoped tokens, but only fail when the file is actually unreadable (matches extract behavior; fixes false “permission denied” on non-scoped paths).
- **Compress UI no longer clobbers closed-archive state** — cancel/error/success messaging, cleanup, and verify results are gated on `compressGeneration`.
- **DMG always stages into a folder** — single files and multi-source selections both go through staging so `hdiutil -srcfolder` is valid; cancel cleans the stage tree.
- **DMG app-installer “Applications” collision** — refuses to delete a real staged item named Applications; shows a clear error instead.
- **TAR symlink listing** — strips `name -> target` to the link name so open/extract target the real entry.
- **ZIP Unix directories** — treat Unix mode `S_IFDIR` in external attributes as directories (not only DOS bit / trailing slash).

## [1.0.15] — 2026-08-08

### Fixed
- **Password retry / reload loading race** — each `loadArchive()` now gets its own generation, so a cancelled prior load cannot clear `isLoading` while a newer unlock/reload is still running.
- **Legacy ZIP file names** — non-UTF-8 entry names fall back to Latin-1 / MacRoman instead of being dropped from the listing.
- **Temp extract disk growth** — extract/preview temp roots are capped (32) with oldest pruned; preview root is preserved while active.
- **DMG password stdin** — process stdin uses full-buffer write so encryption passwords are not truncated.
- **7-Zip progress false positives** — bare numeric lines are no longer treated as percent progress.

## [1.0.14] — 2026-08-08

### Fixed
- **Security-scoped access start/stop pairing** — tokens now stop access on the same URL instance that was started (bookmark re-resolve was unbalanced); removing/releasing tokens fully drops nested begins.
- **Extract destination access captured in the open panel** — bookmarks are taken in the panel callback before any async hop, so Extract / Extract All can write to the chosen folder reliably.
- **ContentView Open panel** — captures security-scoped tokens the same way as the app-menu Open path.

## [1.0.13] — 2026-08-08

### Fixed
- **Folder extract no longer fakes success** — failed folder extract (wrong password, tool error) used to create an empty temp folder and look like it worked for drag-out / open. Failures now surface; empty folders are only created when the archive truly has an empty directory.
- **ZIP open / Quick Look / drag-out without 7-Zip** — single-file and folder temp extract fall back to system `unzip` when 7-Zip is unavailable (same capability as selected extract).
- **Loading state stuck after cancelled ops** — extract / open / verify clear `isLoading` via `defer` so early generation mismatch returns cannot leave the UI stuck busy.
- **Verify integrity uses security-scoped archive tokens** — open-archive verify reuses the same access tokens as browse/extract.
- **Open from Finder / Open panel captures access tokens immediately** — bookmarks are taken while the system open grant is still valid.

## [1.0.12] — 2026-08-08

### Fixed
- **Temp archive cleanup on cancel/failure** — 7z/ZIP/TAR/DMG/ditto compress paths remove partial temp work files when the operation fails or is cancelled (previously 7z always wrote a temp UUID file that the UI cleanup path could miss).
- **Cancel race after process start** — if cancel wins between registration and `process.run()`, the process is terminated immediately after launch.
- **Process run failure no longer risks hanging pipe cleanup** — readability handlers are torn down if `process.run()` throws.
- **TAR compression stages sources** — same in-process staging as ZIP/7z so security-scoped folders and external volumes produce complete archives; cancel is honored during prepare.
- **DMG multi-source name collisions** — duplicate top-level basenames are rejected instead of silently overwriting; cancel is polled while staging.
- **Listing truncation false positive** — archives with exactly 10,000 entries are no longer marked truncated (and Extract All is no longer blocked incorrectly).
- **Extract All without 7-Zip for ZIP** — falls back to system `unzip` when 7-Zip is unavailable.
- **Stronger path safety** — rejects NUL bytes, `~` and Windows-style drive paths; resolves destination symlinks before containment checks; folder extract validates entry paths.
- **Source size status includes hidden trees** — progress size labels no longer skip `.git` / `.build` via `skipsHiddenFiles`.

## [1.0.11] — 2026-08-08

### Fixed
- **Passwords no longer written to compress.log** — arguments starting with `-p` (and `--password=`) are redacted before logging.
- **Real live 7-Zip progress** — `ProcessRunner` now uses `readabilityHandler` / incremental reads instead of `readDataToEndOfFile()` (which only delivered output after the process exited).
- **Cancel during prepare** — staging polls cancellation between top-level items; if cancel wins the race before process registration, the new process is terminated immediately; compressor does not start after cancel.
- **Duplicate top-level names rejected** — two sources that would stage to the same `lastPathComponent` (and silently overwrite) now fail with a clear error.
- **Fewer full-tree walks while staging** — removed post-copy file counting and size walks that undercounted hidden trees / risked symlink resolution.
- **Extract All uses path safety** — lists entries, validates every path (zip-slip), refuses truncated listings, then extracts.

### Changed
- Manual checklist staging section mirrors whole-tree `copyItem` + prune (production 1.0.10+), plus password-redaction / streaming / duplicate-name checks.

## [1.0.10] — 2026-08-08

### Fixed
- **Large Swift projects (e.g. DriveSense with a 200 MB+ `.build` tree)** — prepare now copies each source as a whole tree instead of walking file-by-file, which is faster and avoids hang/edge cases on packages and build caches.
- **7z progress UI** — intended live updates during solid/max compression (completed properly in 1.0.11 streaming fix).
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