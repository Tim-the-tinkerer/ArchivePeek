import Foundation

enum CompressFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case zip
    case dmg
    case sevenZip
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
        case .tar, .tarGzip, .tarBzip2, .tarXz: return "tar"
        case .gzip: return "gzip"
        case .bzip2: return "bzip2"
        case .xz: return "xz"
        }
    }

    var supportsPassword: Bool {
        self == .zip || self == .sevenZip || self == .dmg
    }

    var isZip: Bool {
        self == .zip
    }

    var isDmg: Bool {
        self == .dmg
    }

    /// Output filename extension. Comic-book ZIP uses `.cbz` (ZIP container, CBZ name).
    func outputExtension(comicBookZip: Bool = false) -> String {
        if isZip && comicBookZip {
            return "cbz"
        }
        return fileExtension
    }

    var supportsSolidArchive: Bool {
        self == .sevenZip
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
}