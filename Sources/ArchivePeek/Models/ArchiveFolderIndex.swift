import Foundation

struct ArchiveFolderIndex: Sendable {
    private let childrenByFolder: [String: [ArchiveEntry]]

    init(entries: [ArchiveEntry]) {
        var buckets: [String: [String: ArchiveEntry]] = [:]

        func insert(_ entry: ArchiveEntry, in folder: String, key: String) {
            var children = buckets[folder] ?? [:]
            if let existing = children[key] {
                if existing.isDirectory && !entry.isDirectory {
                    children[key] = entry
                }
            } else {
                children[key] = entry
            }
            buckets[folder] = children
        }

        for entry in entries {
            let normalized = entry.normalizedPath
            guard !normalized.isEmpty else { continue }

            let components = normalized.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            for index in 0..<components.count {
                let folderPath = components.prefix(index).joined(separator: "/")
                let component = components[index]
                let isLast = index == components.count - 1

                if isLast {
                    if entry.isDirectory {
                        let path = folderPath.isEmpty ? "\(component)/" : "\(folderPath)/\(component)/"
                        insert(
                            ArchiveEntry(
                                path: path,
                                isDirectory: true,
                                uncompressedSize: entry.uncompressedSize,
                                compressedSize: entry.compressedSize,
                                modified: entry.modified
                            ),
                            in: folderPath,
                            key: "\(component)/"
                        )
                    } else {
                        let path = folderPath.isEmpty ? component : "\(folderPath)/\(component)"
                        insert(
                            ArchiveEntry(
                                path: path,
                                isDirectory: false,
                                uncompressedSize: entry.uncompressedSize,
                                compressedSize: entry.compressedSize,
                                modified: entry.modified
                            ),
                            in: folderPath,
                            key: component
                        )
                    }
                } else {
                    let path = folderPath.isEmpty ? "\(component)/" : "\(folderPath)/\(component)/"
                    insert(
                        ArchiveEntry(
                            path: path,
                            isDirectory: true,
                            uncompressedSize: 0,
                            compressedSize: nil,
                            modified: nil
                        ),
                        in: folderPath,
                        key: "\(component)/"
                    )
                }
            }
        }

        childrenByFolder = buckets.mapValues { children in
            children.values.sorted(by: Self.sortEntries)
        }
    }

    func children(at folder: String) -> [ArchiveEntry] {
        childrenByFolder[folder] ?? []
    }

    private static func sortEntries(_ lhs: ArchiveEntry, _ rhs: ArchiveEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}