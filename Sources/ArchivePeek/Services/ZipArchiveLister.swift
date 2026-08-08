import Foundation

enum ZipArchiveLister {
    private static let localHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectorySignature: UInt32 = 0x02014b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50
    private static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x07064b50

    static func entries(at url: URL, maxEntries: Int) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ArchiveError.invalidArchive }

        let eocdOffset = try locateEndOfCentralDirectory(in: handle, fileSize: fileSize)
        try handle.seek(toOffset: eocdOffset)
        let eocd = try readExactly(from: handle, count: 22)
        guard readUInt32(eocd, at: 0) == endOfCentralDirectorySignature else {
            throw ArchiveError.invalidArchive
        }

        let totalEntries = Int(readUInt16(eocd, at: 8))
        let entryCount = Int(readUInt16(eocd, at: 10))
        let centralDirectorySize = readUInt32(eocd, at: 12)
        let centralDirectoryOffset = readUInt32(eocd, at: 16)

        if totalEntries == 0xFFFF
            || entryCount == 0xFFFF
            || centralDirectorySize == 0xFFFF_FFFF
            || centralDirectoryOffset == 0xFFFF_FFFF {
            throw ArchiveError.zipRequiresSevenZip
        }

        try handle.seek(toOffset: UInt64(centralDirectoryOffset))
        let centralDirectory = try readExactly(from: handle, count: Int(centralDirectorySize))

        var entries: [ArchiveEntry] = []
        var hasEncryptedEntries = false
        var offset = 0
        let limit = min(entryCount, maxEntries)

        while offset + 46 <= centralDirectory.count, entries.count < limit {
            guard readUInt32(centralDirectory, at: offset) == centralDirectorySignature else { break }

            let generalPurposeFlag = readUInt16(centralDirectory, at: offset + 8)
            if (generalPurposeFlag & 0x0001) != 0 {
                hasEncryptedEntries = true
            }

            var uncompressedSize = Int64(readUInt32(centralDirectory, at: offset + 24))
            var compressedSize = Int64(readUInt32(centralDirectory, at: offset + 20))
            let fileNameLength = Int(readUInt16(centralDirectory, at: offset + 28))
            let extraFieldLength = Int(readUInt16(centralDirectory, at: offset + 30))
            let commentLength = Int(readUInt16(centralDirectory, at: offset + 32))
            let externalAttributes = readUInt32(centralDirectory, at: offset + 38)

            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= centralDirectory.count else { break }

            let nameData = centralDirectory[nameStart..<nameEnd]
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty else {
                offset = nameEnd + extraFieldLength + commentLength
                continue
            }

            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF {
                let extraStart = nameEnd
                let extraEnd = extraStart + extraFieldLength
                if extraEnd <= centralDirectory.count {
                    let extra = centralDirectory[extraStart..<extraEnd]
                    if let zip64 = parseZip64Extra(extra) {
                        if uncompressedSize == 0xFFFF_FFFF, let size = zip64.uncompressed {
                            uncompressedSize = size
                        }
                        if compressedSize == 0xFFFF_FFFF, let size = zip64.compressed {
                            compressedSize = size
                        }
                    }
                }
            }

            let isDirectory = name.hasSuffix("/") || (externalAttributes & 0x10) != 0
            entries.append(
                ArchiveEntry(
                    path: isDirectory && !name.hasSuffix("/") ? name + "/" : name,
                    isDirectory: isDirectory,
                    uncompressedSize: isDirectory ? 0 : uncompressedSize,
                    compressedSize: isDirectory ? nil : compressedSize,
                    modified: nil
                )
            )

            offset = nameEnd + extraFieldLength + commentLength
        }

        if hasEncryptedEntries {
            throw ArchiveError.passwordRequired
        }

        return entries
    }

    private static func locateEndOfCentralDirectory(in handle: FileHandle, fileSize: UInt64) throws -> UInt64 {
        let maxComment = 65_535
        let searchLength = min(fileSize, UInt64(22 + maxComment))
        let start = fileSize - searchLength
        try handle.seek(toOffset: start)
        let tail = try readExactly(from: handle, count: Int(searchLength))

        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            let signature = readUInt32(tail, at: index)
            if signature == zip64EndOfCentralDirectoryLocatorSignature {
                throw ArchiveError.zipRequiresSevenZip
            }
            if signature == endOfCentralDirectorySignature {
                return start + UInt64(index)
            }
        }

        throw ArchiveError.invalidArchive
    }

    private static func parseZip64Extra(_ extra: Data) -> (uncompressed: Int64?, compressed: Int64?)? {
        var offset = 0
        while offset + 4 <= extra.count {
            let headerID = readUInt16(extra, at: offset)
            let dataSize = Int(readUInt16(extra, at: offset + 2))
            let dataStart = offset + 4
            let dataEnd = dataStart + dataSize
            guard dataEnd <= extra.count else { break }

            if headerID == 0x0001 {
                var cursor = dataStart
                var uncompressed: Int64?
                var compressed: Int64?
                if cursor + 8 <= dataEnd {
                    uncompressed = Int64(bitPattern: readUInt64(extra, at: cursor))
                    cursor += 8
                }
                if cursor + 8 <= dataEnd {
                    compressed = Int64(bitPattern: readUInt64(extra, at: cursor))
                }
                return (uncompressed, compressed)
            }

            offset = dataEnd
        }
        return nil
    }

    private static func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        guard count >= 0 else { throw ArchiveError.invalidArchive }
        if count == 0 { return Data() }

        var data = Data()
        data.reserveCapacity(count)

        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count)
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }

        guard data.count == count else { throw ArchiveError.invalidArchive }
        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(readUInt32(data, at: offset))
            | (UInt64(readUInt32(data, at: offset + 4)) << 32)
    }
}