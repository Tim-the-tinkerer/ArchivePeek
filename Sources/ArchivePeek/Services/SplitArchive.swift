import Foundation

/// Multi-volume archives (`.7z.001`, `.zip`+`.z01`, `.part1.rar`, `.rar`+`.r00`).
struct SplitArchiveSet: Equatable, Sendable {
    let firstVolume: URL
    let volumes: [URL]
    let innerFormat: String
    let displayStem: String

    var volumeCount: Int { volumes.count }

    var isMultiVolume: Bool { volumeCount > 1 }

    var formatLabel: String {
        isMultiVolume ? "Split \(innerFormat)" : innerFormat
    }

    var volumeNote: String? {
        guard isMultiVolume else { return nil }
        return "\(volumeCount) volume\(volumeCount == 1 ? "" : "s")"
    }
}

enum SplitArchive {
    private static let numericExtension = try! NSRegularExpression(pattern: #"^\d{3}$"#)
    private static let zipPieceExtension = try! NSRegularExpression(pattern: #"^z\d{2}$"#)
    private static let rarPieceExtension = try! NSRegularExpression(pattern: #"^r\d{2}$"#)
    private static let partName = try! NSRegularExpression(
        pattern: #"^(.+)\.part(\d+)\.(rar|7z|zip)$"#,
        options: [.caseInsensitive]
    )

    static func isSplitVolumeName(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if matches(zipPieceExtension, ext) { return true }
        if matches(rarPieceExtension, ext) { return true }
        if firstMatch(partName, in: filename) != nil { return true }
        if matches(numericExtension, ext) {
            let base = String(filename.dropLast(ext.count + 1))
            return innerFormat(forNumericBase: base) != "Archive"
        }
        return false
    }

    static func set(for url: URL, fileManager: FileManager = .default) -> SplitArchiveSet? {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        let directory = standardized.deletingLastPathComponent()

        if let set = partSet(named: name, in: directory, fileManager: fileManager) {
            return set
        }
        if let set = numericSet(named: name, in: directory, fileManager: fileManager) {
            return set
        }
        if let set = zipZnnSet(named: name, in: directory, fileManager: fileManager) {
            return set
        }
        if let set = rarOldSet(named: name, in: directory, fileManager: fileManager) {
            return set
        }
        return primaryFileSet(named: name, in: directory, fileManager: fileManager)
    }

    static func canonicalURL(for url: URL, fileManager: FileManager = .default) -> URL {
        set(for: url, fileManager: fileManager)?.firstVolume ?? url.standardizedFileURL
    }

    static func uniqueCanonicalArchives(from urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let canonical = canonicalURL(for: url, fileManager: fileManager)
            let key = canonical.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    // MARK: - .partN.rar / .part01.7z / .part1.zip

    private static func partSet(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> SplitArchiveSet? {
        guard let match = firstMatch(partName, in: name) else { return nil }
        let stem = string(in: name, match: match, group: 1)
        let ext = string(in: name, match: match, group: 3).lowercased()
        let width = string(in: name, match: match, group: 2).count
        let pattern = try? NSRegularExpression(
            pattern: "^\(NSRegularExpression.escapedPattern(for: stem))\\.part(\\d+)\\.\(NSRegularExpression.escapedPattern(for: ext))$",
            options: [.caseInsensitive]
        )
        let found = listedMatches(pattern, in: directory, fileManager: fileManager) { text, match in
            Int(string(in: text, match: match, group: 1))
        }
        let firstName = "\(stem).part\(padded(1, width: max(width, 1))).\(ext)"
        let first = existingFile(named: firstName, in: directory, fileManager: fileManager)
            ?? directory.appendingPathComponent(firstName)
        let volumes = found.map(\.url).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let all = volumes.contains(where: { $0.lastPathComponent.lowercased() == first.lastPathComponent.lowercased() })
            ? volumes
            : [first] + volumes
        return SplitArchiveSet(
            firstVolume: first,
            volumes: uniqued(all),
            innerFormat: label(forExtension: ext),
            displayStem: stem
        )
    }

    // MARK: - archive.7z.001 / archive.001

    private static func numericSet(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> SplitArchiveSet? {
        let ext = (name as NSString).pathExtension
        guard matches(numericExtension, ext) else { return nil }
        let base = String(name.dropLast(ext.count + 1))
        guard !base.isEmpty else { return nil }
        let pattern = try? NSRegularExpression(
            pattern: "^\(NSRegularExpression.escapedPattern(for: base))\\.(\\d{3})$",
            options: [.caseInsensitive]
        )
        let found = listedMatches(pattern, in: directory, fileManager: fileManager) { text, match in
            Int(string(in: text, match: match, group: 1))
        }
        let firstName = "\(base).001"
        let first = existingFile(named: firstName, in: directory, fileManager: fileManager)
            ?? directory.appendingPathComponent(firstName)
        let volumes = found.sorted { $0.number < $1.number }.map(\.url)
        let all = volumes.contains(where: { $0.lastPathComponent.lowercased() == first.lastPathComponent.lowercased() })
            ? volumes
            : [first] + volumes
        return SplitArchiveSet(
            firstVolume: first,
            volumes: uniqued(all),
            innerFormat: innerFormat(forNumericBase: base),
            displayStem: displayStem(forBase: base)
        )
    }

    // MARK: - archive.z01 + archive.zip

    private static func zipZnnSet(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> SplitArchiveSet? {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem: String
        if matches(zipPieceExtension, ext) {
            stem = String(name.dropLast(ext.count + 1))
        } else if ext == "zip",
                  existingFile(named: String(name.dropLast(4)) + ".z01", in: directory, fileManager: fileManager) != nil {
            stem = String(name.dropLast(4))
        } else {
            return nil
        }
        guard !stem.isEmpty else { return nil }
        let zipName = "\(stem).zip"
        let first = existingFile(named: zipName, in: directory, fileManager: fileManager)
            ?? directory.appendingPathComponent(zipName)
        let pattern = try? NSRegularExpression(
            pattern: "^\(NSRegularExpression.escapedPattern(for: stem))\\.z(\\d{2})$",
            options: [.caseInsensitive]
        )
        let pieces = listedMatches(pattern, in: directory, fileManager: fileManager) { text, match in
            Int(string(in: text, match: match, group: 1))
        }.sorted { $0.number < $1.number }.map(\.url)
        var volumes = pieces
        if fileManager.fileExists(atPath: first.path) {
            volumes.append(first)
        }
        return SplitArchiveSet(
            firstVolume: first,
            volumes: uniqued(volumes),
            innerFormat: "ZIP",
            displayStem: stem
        )
    }

    // MARK: - archive.rar + archive.r00

    private static func rarOldSet(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> SplitArchiveSet? {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem: String
        if matches(rarPieceExtension, ext) {
            stem = String(name.dropLast(ext.count + 1))
        } else if ext == "rar",
                  existingFile(named: String(name.dropLast(4)) + ".r00", in: directory, fileManager: fileManager) != nil {
            stem = String(name.dropLast(4))
        } else {
            return nil
        }
        guard !stem.isEmpty else { return nil }
        if firstMatch(partName, in: name) != nil { return nil }
        let rarName = "\(stem).rar"
        let first = existingFile(named: rarName, in: directory, fileManager: fileManager)
            ?? directory.appendingPathComponent(rarName)
        let pattern = try? NSRegularExpression(
            pattern: "^\(NSRegularExpression.escapedPattern(for: stem))\\.r(\\d{2})$",
            options: [.caseInsensitive]
        )
        let pieces = listedMatches(pattern, in: directory, fileManager: fileManager) { text, match in
            Int(string(in: text, match: match, group: 1))
        }.sorted { $0.number < $1.number }.map(\.url)
        var volumes = [first] + pieces
        volumes = volumes.filter { fileManager.fileExists(atPath: $0.path) || $0 == first }
        return SplitArchiveSet(
            firstVolume: first,
            volumes: uniqued(volumes),
            innerFormat: "RAR",
            displayStem: stem
        )
    }

    /// Opening `archive.zip` / `archive.7z` / `archive.rar` when extra volumes sit beside it.
    private static func primaryFileSet(
        named name: String,
        in directory: URL,
        fileManager: FileManager
    ) -> SplitArchiveSet? {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = String(name.dropLast(ext.count + (ext.isEmpty ? 0 : 1)))
        guard !stem.isEmpty else { return nil }

        if ext == "zip" {
            return zipZnnSet(named: name, in: directory, fileManager: fileManager)
        }
        if ext == "rar" {
            for candidate in ["\(stem).part1.rar", "\(stem).part01.rar", "\(stem).part001.rar"] {
                if let file = existingFile(named: candidate, in: directory, fileManager: fileManager),
                   let set = partSet(named: file.lastPathComponent, in: directory, fileManager: fileManager) {
                    return set
                }
            }
            return rarOldSet(named: name, in: directory, fileManager: fileManager)
        }
        if ext == "7z" {
            if let firstPiece = existingFile(named: "\(name).001", in: directory, fileManager: fileManager) {
                return numericSet(named: firstPiece.lastPathComponent, in: directory, fileManager: fileManager)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func innerFormat(forNumericBase base: String) -> String {
        let lower = base.lowercased()
        if lower.hasSuffix(".7z") { return "7z" }
        if lower.hasSuffix(".zip") { return "ZIP" }
        if lower.hasSuffix(".rar") { return "RAR" }
        if lower.hasSuffix(".tar") || lower.contains(".tar.") { return "TAR" }
        return "Archive"
    }

    private static func displayStem(forBase base: String) -> String {
        var name = base
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".7z", ".zip", ".rar", ".tar"] {
            if lower.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? base : trimmed
    }

    private static func label(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "7z": return "7z"
        case "zip": return "ZIP"
        case "rar": return "RAR"
        default: return ext.uppercased()
        }
    }

    private static func padded(_ value: Int, width: Int) -> String {
        String(format: "%0\(width)d", value)
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    private static func existingFile(named name: String, in directory: URL, fileManager: FileManager) -> URL? {
        let candidate = directory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let lower = name.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return items.first {
            $0.lastPathComponent.lowercased(with: Locale(identifier: "en_US_POSIX")) == lower
        }?.standardizedFileURL
    }

    private static func listedMatches(
        _ regex: NSRegularExpression?,
        in directory: URL,
        fileManager: FileManager,
        number: (String, NSTextCheckingResult) -> Int?
    ) -> [(number: Int, url: URL)] {
        guard let regex else { return [] }
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [(Int, URL)] = []
        for item in items {
            let name = item.lastPathComponent
            guard let match = regex.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)
            ), let value = number(name, match) else { continue }
            result.append((value, item.standardizedFileURL))
        }
        return result
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func string(in text: String, match: NSTextCheckingResult, group: Int) -> String {
        guard let range = Range(match.range(at: group), in: text) else { return "" }
        return String(text[range])
    }
}
