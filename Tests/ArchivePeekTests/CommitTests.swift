@testable import ArchivePeekCore
import XCTest

final class CommitTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePeek-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSuccessfulCommitReplacesThePreviousArchive() throws {
        let finalURL = directory.appendingPathComponent("old.zip")
        try Data("OLD".utf8).write(to: finalURL)
        let destination = try stagedDestination(named: "new.zip", bytes: Data("NEW".utf8), finalURL: finalURL)

        try CompressionSupport.finalizeCompressionDestination(destination) { _ in }

        XCTAssertEqual(try Data(contentsOf: finalURL), Data("NEW".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.workURL.path))
        XCTAssertTrue(partials().isEmpty)
    }

    func testNewArchiveIsCreatedWhenNothingIsThereYet() throws {
        let finalURL = directory.appendingPathComponent("fresh.zip")
        let destination = try stagedDestination(named: "fresh-work.zip", bytes: Data("NEW".utf8), finalURL: finalURL)

        try CompressionSupport.finalizeCompressionDestination(destination)

        XCTAssertEqual(try Data(contentsOf: finalURL), Data("NEW".utf8))
        XCTAssertTrue(partials().isEmpty)
    }

    func testVerificationFailureLeavesThePreviousArchive() throws {
        let finalURL = directory.appendingPathComponent("old.zip")
        try Data("OLD".utf8).write(to: finalURL)
        let destination = try stagedDestination(named: "new.zip", bytes: Data("NEW".utf8), finalURL: finalURL)

        XCTAssertThrowsError(try CompressionSupport.finalizeCompressionDestination(destination) { _ in
            throw ArchiveError.commandFailed("verify failed")
        }) { error in
            guard let archiveError = error as? ArchiveError, case .commandFailed = archiveError else {
                return XCTFail("expected commandFailed, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: finalURL), Data("OLD".utf8))
        XCTAssertTrue(partials().isEmpty)
    }

    func testVerificationCancellationStaysCancelledAndLeavesThePreviousArchive() throws {
        let finalURL = directory.appendingPathComponent("old.zip")
        try Data("OLD".utf8).write(to: finalURL)
        let destination = try stagedDestination(named: "new.zip", bytes: Data("NEW".utf8), finalURL: finalURL)

        XCTAssertThrowsError(try CompressionSupport.finalizeCompressionDestination(destination) { _ in
            throw ArchiveError.cancelled
        }) { error in
            guard let archiveError = error as? ArchiveError, case .cancelled = archiveError else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: finalURL), Data("OLD".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.workURL.path))
        XCTAssertTrue(partials().isEmpty)
    }

    private func stagedDestination(named workName: String, bytes: Data, finalURL: URL) throws -> CompressionSupport.CompressionDestination {
        let workURL = directory.appendingPathComponent(workName)
        try bytes.write(to: workURL)
        return CompressionSupport.CompressionDestination(
            workURL: workURL,
            finalURL: finalURL,
            shouldRelocate: true
        )
    }

    private func partials() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(".ArchivePeek-") }
    }
}
