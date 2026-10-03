import Foundation

enum AppSettings {
    enum Keys {
        static let compressFormat = "defaultCompressFormat"
        static let compressionLevel = "defaultCompressionLevel"
        static let verifyAfterCompress = "verifyAfterCompress"
        static let solidArchive = "defaultSolidArchive"
        static let dmgAppInstaller = "defaultDmgAppInstaller"
        static let comicBookZip = "defaultComicBookZip"
        static let zipMethod = "defaultZipMethod"
        static let finderContextMenu = "finderContextMenu"
        static let customExclusions = "customExclusionPatterns"
    }

    private static let store = UserDefaults.standard

    static var defaultCompressFormat: CompressFormat {
        get {
            guard let raw = store.string(forKey: Keys.compressFormat),
                  let format = CompressFormat(rawValue: raw) else {
                return CompressFormat.defaultFormat
            }
            return format
        }
        set {
            store.set(newValue.rawValue, forKey: Keys.compressFormat)
        }
    }

    private static let supportedCompressionLevels = [0, 1, 5, 9]

    static var defaultCompressionLevel: Int {
        get {
            let level = store.object(forKey: Keys.compressionLevel) as? Int ?? 5
            return normalizedCompressionLevel(level)
        }
        set {
            store.set(normalizedCompressionLevel(newValue), forKey: Keys.compressionLevel)
        }
    }

    /// Settings offers Store, Fast, Normal, and Maximum. Older saved values
    /// (for example 3) snap to the nearest of those so the picker has a selection.
    static func normalizedCompressionLevel(_ level: Int) -> Int {
        let clamped = min(max(level, 0), 9)
        return supportedCompressionLevels.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? 5
    }

    static var defaultVerifyAfterCompress: Bool {
        get { store.object(forKey: Keys.verifyAfterCompress) as? Bool ?? true }
        set { store.set(newValue, forKey: Keys.verifyAfterCompress) }
    }

    static var defaultSolidArchive: Bool {
        get { store.bool(forKey: Keys.solidArchive) }
        set { store.set(newValue, forKey: Keys.solidArchive) }
    }

    static var defaultDmgAppInstaller: Bool {
        get { store.bool(forKey: Keys.dmgAppInstaller) }
        set { store.set(newValue, forKey: Keys.dmgAppInstaller) }
    }

    static var defaultComicBookZip: Bool {
        get { store.bool(forKey: Keys.comicBookZip) }
        set { store.set(newValue, forKey: Keys.comicBookZip) }
    }

    static var defaultZipMethod: ZipCompressionMethod {
        get {
            guard let raw = store.string(forKey: Keys.zipMethod),
                  let method = ZipCompressionMethod(rawValue: raw) else {
                return .defaultMethod
            }
            return method
        }
        set { store.set(newValue.rawValue, forKey: Keys.zipMethod) }
    }

    static var finderContextMenuEnabled: Bool {
        get { store.bool(forKey: Keys.finderContextMenu) }
        set { store.set(newValue, forKey: Keys.finderContextMenu) }
    }

    /// Extra names and patterns left out of new archives. Empty until the user adds one.
    /// macOS junk is always removed and is not part of this list.
    static var customExclusionPatterns: [String] {
        get { sanitizedExclusionPatterns(store.stringArray(forKey: Keys.customExclusions) ?? []) }
        set { store.set(sanitizedExclusionPatterns(newValue), forKey: Keys.customExclusions) }
    }

    /// Nil when the pattern was added. Otherwise a message suitable for Settings.
    static func addCustomExclusion(_ raw: String) -> String? {
        let pieces = raw.split(whereSeparator: \.isNewline).map(String.init)
        let lines = pieces.isEmpty ? [raw] : pieces
        var current = customExclusionPatterns
        var firstError: String?
        var added = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            switch ArchiveExclusions.parse(line) {
            case .rejected(let message):
                if firstError == nil { firstError = message }
            case .accepted(let pattern):
                if current.contains(where: { sameExclusion($0, pattern) }) {
                    if firstError == nil { firstError = "That exclusion is already in the list." }
                    continue
                }
                if current.count >= ArchiveExclusions.maxCount {
                    if firstError == nil {
                        firstError = "The list can hold \(ArchiveExclusions.maxCount) exclusions."
                    }
                    continue
                }
                current.append(pattern)
                added += 1
            }
        }
        if added > 0 {
            customExclusionPatterns = current
        }
        if added > 0, firstError == nil {
            return nil
        }
        return firstError ?? "Enter a name or pattern."
    }

    static func removeCustomExclusion(_ pattern: String) {
        customExclusionPatterns = customExclusionPatterns.filter { !sameExclusion($0, pattern) }
    }

    private static func sanitizedExclusionPatterns(_ patterns: [String]) -> [String] {
        var result: [String] = []
        for pattern in patterns {
            guard case .accepted(let display) = ArchiveExclusions.parse(pattern) else { continue }
            if result.contains(where: { sameExclusion($0, display) }) { continue }
            result.append(display)
            if result.count == ArchiveExclusions.maxCount { break }
        }
        return result
    }

    private static func sameExclusion(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased(with: Locale(identifier: "en_US_POSIX"))
            == rhs.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    @MainActor
    static func applyCompressionDefaults(to browser: ArchiveBrowserModel) {
        browser.compressFormat = defaultCompressFormat
        browser.compressionLevel = defaultCompressionLevel
        browser.verifyAfterCompress = defaultVerifyAfterCompress
        browser.compressSolidArchive = defaultSolidArchive
        // App-installer layout is DMG-only. Never leave the flag on for ZIP/7z/etc.
        // (That used to block Create Archive with a misleading installer/.app error.)
        browser.compressDmgAppInstaller = defaultDmgAppInstaller && defaultCompressFormat.isDmg
        browser.compressSaveAsComicBookZip = defaultComicBookZip && defaultCompressFormat.isZip
        browser.compressZipMethod = defaultZipMethod
        browser.compressSplitVolume = .off
    }
}