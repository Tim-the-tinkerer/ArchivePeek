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
            var compressionMethod = readUInt16(centralDirectory, at: offset + 10)

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
            // Prefer UTF-8 (general-purpose bit 11 / modern tools); fall back for legacy OEM/Latin names.
            // Never silently drop members: Extract All validates only listed paths.
            let name = decodeZipFileName(nameData, generalPurposeFlag: generalPurposeFlag)
            guard let name, !name.isEmpty else {
                // Undecodable / empty CD names — hand off to 7-Zip rather than under-report.
                throw ArchiveError.zipRequiresSevenZip
            }

            let extraStart = nameEnd
            let extraEnd = extraStart + extraFieldLength
            let extra = extraEnd <= centralDirectory.count
                ? centralDirectory[extraStart..<extraEnd]
                : Data()
            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF {
                if let zip64 = parseZip64Extra(extra) {
                    if uncompressedSize == 0xFFFF_FFFF, let size = zip64.uncompressed {
                        uncompressedSize = size
                    }
                    if compressedSize == 0xFFFF_FFFF, let size = zip64.compressed {
                        compressedSize = size
                    }
                }
            }
            // Method 99 is WinZip AES. The real compression method is inside extra field 0x9901.
            if compressionMethod == 99, let inner = aesCompressionMethod(in: extra) {
                compressionMethod = inner
            }

            // DOS dir bit (0x10) and Unix mode in high 16 bits (S_IFDIR = 0040000).
            let unixMode = (externalAttributes >> 16) & 0o170000
            let isDirectory = name.hasSuffix("/")
                || (externalAttributes & 0x10) != 0
                || unixMode == 0o040000
            entries.append(
                ArchiveEntry(
                    path: isDirectory && !name.hasSuffix("/") ? name + "/" : name,
                    isDirectory: isDirectory,
                    uncompressedSize: isDirectory ? 0 : uncompressedSize,
                    compressedSize: isDirectory ? nil : compressedSize,
                    modified: nil,
                    compressionMethod: isDirectory ? nil : methodName(for: compressionMethod)
                )
            )

            offset = nameEnd + extraFieldLength + commentLength
        }

        if hasEncryptedEntries {
            throw ArchiveError.passwordRequired
        }

        // If the central directory claims more records than we could parse cleanly, prefer 7-Zip
        // so Extract All path validation is not based on an incomplete list.
        let expected = min(entryCount, maxEntries)
        if entryCount > 0, entries.count < expected {
            throw ArchiveError.zipRequiresSevenZip
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
            // A comment can contain the same 4 bytes. Only an EOCD whose comment
            // length lands on EOF is real (APPNOTE). Zip64 is detected later from
            // the 0xFFFF fields; a locator signature inside the comment is not one.
            if signature == zip64EndOfCentralDirectoryLocatorSignature {
                continue
            }
            if signature == endOfCentralDirectorySignature {
                let commentLength = Int(readUInt16(tail, at: index + 20))
                if index + 22 + commentLength == tail.count {
                    return start + UInt64(index)
                }
            }
        }

        throw ArchiveError.invalidArchive
    }

    /// Names match the words 7-Zip prints for the same ZIP method numbers.
    static func methodName(for code: UInt16) -> String {
        switch code {
        case 0: return "Store"
        case 1: return "Shrink"
        case 2, 3, 4, 5: return "Reduce"
        case 6, 10: return "Implode"
        case 8: return "Deflate"
        case 9: return "Deflate64"
        case 12: return "BZip2"
        case 14: return "LZMA"
        case 18: return "TERSE"
        case 19: return "LZ77"
        case 93: return "Zstd"
        case 94: return "MP3"
        case 95: return "XZ"
        case 96: return "JPEG"
        case 97: return "WavPack"
        case 98: return "PPMd"
        case 99: return "AES"
        default: return "Method \(code)"
        }
    }

    /// WinZip AES extra field 0x9901 stores the compression method that was wrapped.
    private static func aesCompressionMethod(in extra: Data) -> UInt16? {
        var offset = 0
        while offset + 4 <= extra.count {
            let headerID = readUInt16(extra, at: offset)
            let dataSize = Int(readUInt16(extra, at: offset + 2))
            let dataStart = offset + 4
            let dataEnd = dataStart + dataSize
            guard dataEnd <= extra.count else { break }
            // version(2) + "AE"(2) + strength(1) + method(2)
            if headerID == 0x9901, dataSize >= 7 {
                return readUInt16(extra, at: dataStart + 5)
            }
            offset = dataEnd
        }
        return nil
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

    private static func decodeZipFileName(_ data: Data, generalPurposeFlag: UInt16) -> String? {
        guard !data.isEmpty else { return nil }
        // Bit 11 = language encoding flag (UTF-8).
        if (generalPurposeFlag & 0x0800) != 0 {
            if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                return utf8
            }
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return utf8
        }
        // Common legacy code pages for non-UTF-8 ZIP names.
        if let latin1 = String(data: data, encoding: .isoLatin1), !latin1.isEmpty {
            return latin1
        }
        if let macRoman = String(data: data, encoding: .macOSRoman), !macRoman.isEmpty {
            return macRoman
        }
        if let ascii = String(data: data, encoding: .ascii), !ascii.isEmpty {
            return ascii
        }
        // Lossy UTF-8 so we still surface a path for validation rather than dropping the member.
        let lossy = String(decoding: data, as: UTF8.self)
        return lossy.isEmpty ? nil : lossy
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