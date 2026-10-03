@testable import ArchivePeekCore
import XCTest

final class ListingMethodTests: XCTestCase {
    func testZipMethodNamesMatchTheWordsShownInTheList() {
        XCTAssertEqual(ZipArchiveLister.methodName(for: 0), "Store")
        XCTAssertEqual(ZipArchiveLister.methodName(for: 8), "Deflate")
        XCTAssertEqual(ZipArchiveLister.methodName(for: 9), "Deflate64")
        XCTAssertEqual(ZipArchiveLister.methodName(for: 14), "LZMA")
        XCTAssertEqual(ZipArchiveLister.methodName(for: 42), "Method 42")
    }

    func testSevenZipListingKeepsTheMethodOnFiles() {
        let listing = """
        Path = notes.txt
        Size = 12
        Packed Size = 8
        Method = Deflate64
        Attributes = A

        Path = Folder
        Size = 0
        Method = Store
        Attributes = D

        Path = big.bin
        Size = 100
        Packed Size = 40
        Method = LZMA2:24
        Attributes = A

        Path = empty.txt
        Size = 0
        Packed Size = 0
        Method =
        Attributes = A
        """
        let methods = SevenZipBackend.parseListing(listing).entries.map(\.compressionMethod)
        XCTAssertEqual(methods, ["Deflate64", nil, "LZMA2:24", nil])
    }

    func testFolderRowsKeepAFileMethod() {
        let entry = ArchiveEntry(
            path: "dir/a.txt",
            isDirectory: false,
            uncompressedSize: 4,
            compressedSize: 2,
            modified: nil,
            compressionMethod: "Deflate64"
        )
        let index = ArchiveFolderIndex(entries: [entry])
        XCTAssertEqual(index.children(at: "dir").first?.compressionMethod, "Deflate64")
        XCTAssertNil(index.children(at: "").first?.compressionMethod)
    }

    func testZipCentralDirectoryReportsStoreAndDeflate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePeek-method-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("sample.txt")
        try Data(String(repeating: "hello deflate ", count: 400).utf8).write(to: source)

        let stored = directory.appendingPathComponent("stored.zip")
        try zip(level: 0, archive: stored, source: source, directory: directory)
        let storedMethod = try ZipArchiveLister.entries(at: stored, maxEntries: 20)
            .first { !$0.isDirectory }?.compressionMethod
        XCTAssertEqual(storedMethod, "Store")

        let deflated = directory.appendingPathComponent("deflated.zip")
        try zip(level: 9, archive: deflated, source: source, directory: directory)
        let deflatedMethod = try ZipArchiveLister.entries(at: deflated, maxEntries: 20)
            .first { !$0.isDirectory }?.compressionMethod
        XCTAssertEqual(deflatedMethod, "Deflate")
    }

    private func zip(level: Int, archive: URL, source: URL, directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-\(level)", archive.path, source.lastPathComponent]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ArchiveError.commandFailed(error.isEmpty ? "zip failed" : error)
        }
    }
}
