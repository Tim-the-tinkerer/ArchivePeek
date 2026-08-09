import Foundation

enum AppSettings {
    enum Keys {
        static let compressFormat = "defaultCompressFormat"
        static let compressionLevel = "defaultCompressionLevel"
        static let verifyAfterCompress = "verifyAfterCompress"
        static let solidArchive = "defaultSolidArchive"
        static let dmgAppInstaller = "defaultDmgAppInstaller"
        static let comicBookZip = "defaultComicBookZip"
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
            return nearestCompressionLevel(to: level)
        }
        set {
            store.set(nearestCompressionLevel(to: newValue), forKey: Keys.compressionLevel)
        }
    }

    private static func nearestCompressionLevel(to level: Int) -> Int {
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
    }
}