import Foundation

enum ArchiveError: LocalizedError {
    case unsupportedFormat
    case toolUnavailable(String)
    case commandFailed(String)
    case invalidArchive
    case zipRequiresSevenZip
    case invalidEntryPath(String)
    case passwordRequired
    case entryNotFound(String)
    case invalidSelection
    case cancelled
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported archive format."
        case .toolUnavailable(let tool):
            return "\(tool) is not available. Install with: brew install sevenzip"
        case .commandFailed(let message):
            return message
        case .invalidArchive:
            return "The archive appears to be invalid or corrupt."
        case .zipRequiresSevenZip:
            return "This ZIP archive requires 7-Zip to open."
        case .invalidEntryPath(let path):
            return "Blocked unsafe archive path: \"\(path)\"."
        case .passwordRequired:
            return "This archive is password protected."
        case .entryNotFound(let path):
            return "Could not find \"\(path)\" in the archive."
        case .invalidSelection:
            return "Select one or more files or folders to compress."
        case .cancelled:
            return "Operation cancelled."
        case .permissionDenied(let name):
            return "ArchivePeek does not have permission to read \"\(name)\". Add all items in one Add Files selection, or grant access when macOS prompts."
        }
    }
}