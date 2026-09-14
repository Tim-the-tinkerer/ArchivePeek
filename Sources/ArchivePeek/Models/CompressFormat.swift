import Foundation

enum CompressFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case zip
    case dmg
    case sevenZip
    case rar
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
    case gzip
    case bzip2
    case xz

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip: return "ZIP"
        case .dmg: return "DMG"
        case .sevenZip: return "7z"
        case .rar: return "RAR"
        case .tar: return "TAR"
        case .tarGzip: return "TAR.GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        case .gzip: return "GZIP"
        case .bzip2: return "BZIP2"
        case .xz: return "XZ"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .dmg: return "dmg"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        }
    }

    var sevenZipType: String {
        switch self {
        case .zip: return "zip"
        case .dmg: return "dmg"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        case .tar, .tarGzip, .tarBzip2, .tarXz: return "tar"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        }
    }

    var supportsPassword: Bool {
        self == .zip || self == .sevenZip || self == .rar || self == .dmg
    }

    var isZip: Bool {
        self == .zip
    }

    var isDmg: Bool {
        self == .dmg
    }

    var isRar: Bool {
        self == .rar
    }

    /// ZIP, 7z, and RAR can be written as numbered volumes.
    var supportsSplitVolumes: Bool {
        self == .zip || self == .sevenZip || self == .rar
    }

    /// Output filename extension. Comic-book ZIP uses `.cbz` (ZIP container, CBZ name).
    func outputExtension(comicBookZip: Bool = false) -> String {
        if isZip && comicBookZip {
            return "cbz"
        }
        return fileExtension
    }

    var supportsSolidArchive: Bool {
        self == .sevenZip || self == .rar
    }

    var requiresSingleFile: Bool {
        self == .gzip || self == .bzip2 || self == .xz
    }

    var isTarFamily: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXz: return true
        default: return false
        }
    }

    var bsdtarCompressionFlag: String {
        switch self {
        case .tar: return ""
        case .tarGzip: return "-z"
        case .tarBzip2: return "-j"
        case .tarXz: return "-J"
        default: return ""
        }
    }

    static var defaultFormat: CompressFormat { .zip }

    /// RAR `-m` 0…5 from ArchivePeek’s 0/1/5/9 picker.
    static func rarMethod(forCompressionLevel level: Int) -> Int {
        switch level {
        case 0: return 0
        case 1: return 1
        case 9: return 5
        default: return 3
        }
    }
}

enum SplitVolumePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off
    case mb1
    case mb10
    case mb25
    case mb100
    case mb250
    case mb700
    case gb1
    case gb2
    case gb4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .mb1: return "1 MB"
        case .mb10: return "10 MB"
        case .mb25: return "25 MB"
        case .mb100: return "100 MB"
        case .mb250: return "250 MB"
        case .mb700: return "700 MB (CD)"
        case .gb1: return "1 GB"
        case .gb2: return "2 GB"
        case .gb4: return "4 GB"
        }
    }

    var isEnabled: Bool { self != .off }

    /// 7-Zip / RAR `-v` size token (`100m`, `1g`).
    var volumeArgument: String? {
        switch self {
        case .off: return nil
        case .mb1: return "1m"
        case .mb10: return "10m"
        case .mb25: return "25m"
        case .mb100: return "100m"
        case .mb250: return "250m"
        case .mb700: return "700m"
        case .gb1: return "1g"
        case .gb2: return "2g"
        case .gb4: return "4g"
        }
    }
}