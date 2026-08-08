import Foundation

enum ToolLocator {
    private static let bundledToolsFolder = "Tools"
    private static let cacheLock = NSLock()
    private static var materializedSevenZipPath: String?

    static var sevenZipPath: String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let materializedSevenZipPath,
           FileManager.default.isExecutableFile(atPath: materializedSevenZipPath) {
            return materializedSevenZipPath
        }

        if let bundled = bundledExecutable(named: "7zz") ?? bundledExecutable(named: "7z"),
           let materialized = materializeBundledTool(from: bundled, named: "7zz") {
            materializedSevenZipPath = materialized
            return materialized
        }

        return locateSystem(executables: ["7zz", "7z", "7za", "7zr"])
    }

    static var bsdtarPath: String? {
        if let bundled = bundledExecutable(named: "bsdtar") {
            return bundled
        }
        for path in ["/usr/bin/bsdtar", "/opt/homebrew/bin/bsdtar", "/usr/local/bin/bsdtar"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return locateSystem(executables: ["bsdtar"])
    }

    static var unzipPath: String? {
        if let bundled = bundledExecutable(named: "unzip") {
            return bundled
        }
        let path = "/usr/bin/unzip"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var zipPath: String? {
        if let bundled = bundledExecutable(named: "zip") {
            return bundled
        }
        let path = "/usr/bin/zip"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var dittoPath: String? {
        let path = "/usr/bin/ditto"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var hdiutilPath: String? {
        let path = "/usr/bin/hdiutil"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var isSevenZipAvailable: Bool { sevenZipPath != nil }

    static var usesBundledSevenZip: Bool {
        guard bundleToolsDirectory != nil else { return false }
        return bundledExecutable(named: "7zz") != nil || bundledExecutable(named: "7z") != nil
    }

    static var bundledSevenZipVersion: String? {
        usesBundledSevenZip ? "26.02" : nil
    }

    static var statusSummary: String {
        var parts: [String] = []
        if let sevenZip = sevenZipPath {
            if usesBundledSevenZip, let version = bundledSevenZipVersion {
                parts.append("7-Zip \(version) (bundled)")
            } else {
                parts.append("7-Zip (system): \(URL(fileURLWithPath: sevenZip).lastPathComponent)")
            }
        } else {
            parts.append("7-Zip: not available")
        }
        if let bsdtarPath {
            let bundled = bundleToolsDirectory.map { bsdtarPath.hasPrefix($0.path) } ?? false
            parts.append("bsdtar (\(bundled ? "bundled" : "system"))")
        }
        if zipPath != nil {
            parts.append("zip (system)")
        }
        if hdiutilPath != nil {
            parts.append("hdiutil (system)")
        }
        return parts.joined(separator: " · ")
    }

    private static var bundleToolsDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(bundledToolsFolder, isDirectory: true)
    }

    private static func bundledExecutable(named name: String) -> String? {
        guard let toolsDirectory = bundleToolsDirectory else { return nil }
        let path = toolsDirectory.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// macOS kills helpers executed directly from app Resources (exit 9). Copy to Application Support first.
    private static func materializeBundledTool(from bundledPath: String, named name: String) -> String? {
        let fileManager = FileManager.default
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArchivePeek/Tools", isDirectory: true)

        do {
            try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        } catch {
            CompressDiagnostics.log("could not create tools cache: \(error.localizedDescription)")
            return nil
        }

        let destination = supportRoot.appendingPathComponent(name)
        let bundledURL = URL(fileURLWithPath: bundledPath)

        if shouldRefreshTool(source: bundledURL, destination: destination, fileManager: fileManager) {
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: bundledURL, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                clearQuarantine(at: destination)
                CompressDiagnostics.log("materialized \(name) → \(destination.path)")
            } catch {
                CompressDiagnostics.log("could not materialize \(name): \(error.localizedDescription)")
                return nil
            }
        }

        guard fileManager.isExecutableFile(atPath: destination.path),
              verifyToolRuns(at: destination.path) else {
            CompressDiagnostics.log("materialized \(name) failed smoke test")
            return nil
        }

        return destination.path
    }

    private static func shouldRefreshTool(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else { return true }
        guard let sourceDate = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let destDate = try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return true
        }
        return sourceDate > destDate
    }

    private static func clearQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func verifyToolRuns(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func locateSystem(executables: [String]) -> String? {
        for name in executables {
            let candidates = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/opt/local/bin/\(name)",
                "/usr/bin/\(name)",
            ]
            for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}