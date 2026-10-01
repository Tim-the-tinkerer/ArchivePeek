@testable import ArchivePeekCore
import XCTest

final class SafetyAndFormatTests: XCTestCase {
    func testListedDotPathsNormalizeWithoutAcceptingDotComponents() {
        XCTAssertEqual(PathSafety.normalizeListedPath("./sub/f.txt"), "sub/f.txt")
        XCTAssertNil(PathSafety.normalizeListedPath("."))
        XCTAssertNil(PathSafety.normalizeListedPath("./"))
        XCTAssertThrowsError(try PathSafety.validateArchiveEntryPath("./sub/f.txt"))
        XCTAssertThrowsError(try PathSafety.validateArchiveEntryPath("dir/file*.txt"))
    }

    func testContainmentRemovesLinksThatLeaveTheDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePeek-contain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inside = root.appendingPathComponent("inside.txt")
        try Data("ok".utf8).write(to: inside)
        let safe = root.appendingPathComponent("safe-link")
        try FileManager.default.createSymbolicLink(atPath: safe.path, withDestinationPath: "inside.txt")
        let outside = root.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(atPath: outside.path, withDestinationPath: "/etc/passwd")

        XCTAssertThrowsError(try PathSafety.enforceExtractContainment(in: root))
        XCTAssertTrue(isLink(safe))
        XCTAssertFalse(isLink(outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
    }

    func testExclusionsKeepNestedFilesThatASlashCrossingStarWouldDrop() {
        XCTAssertTrue(ArchiveExclusions.excludes("src/main.swift", patterns: ["src/*.swift"]))
        XCTAssertFalse(ArchiveExclusions.excludes("src/Util/main.swift", patterns: ["src/*.swift"]))
        XCTAssertTrue(ArchiveExclusions.excludes("lib/node_modules/a.js", patterns: ["node_modules"]))
        guard case .rejected = ArchiveExclusions.parse("*") else {
            return XCTFail("a pattern that excludes everything was accepted")
        }
    }

    func testVersionCompareTreatsPrereleaseAsOlder() {
        XCTAssertTrue(UpdateChecker.isRemoteVersion("1.0.10", newerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isRemoteVersion("1.0.35-beta", newerThan: "1.0.35"))
        XCTAssertFalse(UpdateChecker.isRemoteVersion("v1.0.35+9", newerThan: "1.0.35"))
        XCTAssertTrue(UpdateChecker.isRemoteVersion("1.0.36", newerThan: "1.0.35-beta"))
    }

    func testProgressParsersDoNotTreatAFilenamePercentAsCompletion() {
        let sevenZip = SevenZipProgressParser()
        let named = sevenZip.ingest("+ 100%.txt\n")
        XCTAssertNotNil(named)
        XCTAssertLessThan(named?.fraction ?? 1, 0.5)

        let percent = sevenZip.ingest("  40%\n")
        XCTAssertEqual(percent?.fraction ?? 0, 0.4, accuracy: 0.001)

        let zip = ZipProgressParser()
        _ = zip.ingest("adding: a.txt (stored 0%)\n")
        let second = zip.ingest("updating: b.txt (deflated 12%)\n")
        XCTAssertEqual(second?.fraction ?? 0, 0.02, accuracy: 0.0001)
        XCTAssertTrue(second?.message.contains("b.txt") == true)
        XCTAssertFalse(second?.message.contains("deflated") == true)
    }

    func testAPlainArchiveIsNotPartOfANumberedVolumeSet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePeek-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plain = root.appendingPathComponent("Backup.7z")
        let first = root.appendingPathComponent("Backup.7z.001")
        let second = root.appendingPathComponent("Backup.7z.002")
        try Data("plain".utf8).write(to: plain)
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        XCTAssertNil(SplitArchive.set(for: plain))
        let set = try XCTUnwrap(SplitArchive.set(for: first))
        XCTAssertEqual(set.volumes.count, 2)
        XCTAssertFalse(set.volumes.contains { $0.lastPathComponent == "Backup.7z" })
    }

    private func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
