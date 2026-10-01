import Foundation

/// User patterns for files and folders left out of new archives.
///
/// A pattern with no `/` matches that file or folder name anywhere in the tree.
/// A pattern with `/` matches that sequence of names. `*` and `?` are wildcards
/// within a single name. `**` is its own path part and matches any number of folders.
/// Matching is case-insensitive. macOS junk is handled separately and always applies.
enum ArchiveExclusions {
    static let maxCount = 64
    static let maxLength = 240

    private struct Compiled: Equatable {
        enum Segment: Equatable {
            case globstar
            case glob(String)
        }

        let segments: [Segment]
    }

    /// Canonical pattern text, or a message explaining why the text was rejected.
    static func parse(_ raw: String) -> PatternParse {
        switch compile(raw) {
        case .success(let compiled):
            return .accepted(compiled.display)
        case .failure(let message):
            return .rejected(message)
        }
    }

    static func excludes(_ relativePath: String, patterns: [String]) -> Bool {
        Matcher(patterns: patterns).excludes(relativePath)
    }

    /// Compiled once per archive so a large tree does not re-parse the list for every path.
    struct Matcher {
        private let patterns: [Compiled]

        init(patterns displays: [String]) {
            patterns = displays.compactMap { display in
                guard case .success(let compiled) = ArchiveExclusions.compile(display) else { return nil }
                return compiled.compiled
            }
        }

        func excludes(_ relativePath: String) -> Bool {
            let parts = ArchiveExclusions.pathComponents(relativePath)
            guard !parts.isEmpty else { return false }
            var prefix: [String] = []
            prefix.reserveCapacity(parts.count)
            for part in parts {
                prefix.append(part)
                if patterns.contains(where: { ArchiveExclusions.matches(prefix, pattern: $0) }) {
                    return true
                }
            }
            return false
        }
    }

    /// Patterns handed to `zip -x`, `bsdtar --exclude`, and `7zz -xr!`.
    /// Staging is the source of truth. Those tools let `*` cross `/`, so pass `wildcards: false`
    /// and keep wildcard patterns out of the tool command.
    static func archiveToolPatterns(for displays: [String], wildcards: Bool = true) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for display in displays {
            guard case .accepted = parse(display) else { continue }
            // zip, bsdtar, and 7-Zip let `*` cross `/`. A pattern such as `src/*.swift`
            // would then drop `src/Util/main.swift`. Staging already applied the
            // stricter match, so those tools only receive literal patterns.
            if !wildcards && (display.contains("*") || display.contains("?")) { continue }
            for pattern in expandToolPattern(display) {
                let key = pattern.lowercased(with: Locale(identifier: "en_US_POSIX"))
                if seen.insert(key).inserted {
                    result.append(pattern)
                }
            }
        }
        return result
    }

    enum PatternParse {
        case accepted(String)
        case rejected(String)
    }

    private enum CompileResult {
        case success(CompiledPattern)
        case failure(String)
    }

    private struct CompiledPattern {
        let display: String
        let compiled: Compiled
    }

    private static func compile(_ raw: String) -> CompileResult {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return .failure("Enter a name or pattern.")
        }
        if text.count > maxLength {
            return .failure("That pattern is too long.")
        }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure("That pattern contains an unsupported character.")
        }
        if text.contains("\\") {
            return .failure("Use / between folder names.")
        }
        if text.hasPrefix("-") {
            return .failure("A pattern cannot start with -.")
        }
        if text.hasPrefix("/") {
            return .failure("Use a name or a relative path, not a full path.")
        }
        while text.hasPrefix("./") {
            text.removeFirst(2)
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "." || text == ".." {
            return .failure("That pattern would not match a file.")
        }

        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty }) {
            return .failure("Use a single / between names.")
        }
        if parts.contains(".") || parts.contains("..") {
            return .failure("Patterns cannot contain . or ..")
        }

        var segments: [Compiled.Segment] = []
        var globstars = 0
        for part in parts {
            if part == "**" {
                globstars += 1
                if globstars > 1 {
                    return .failure("Use ** only once in a pattern.")
                }
                segments.append(.globstar)
            } else if part.contains("**") {
                return .failure("Use ** as its own path part, as in logs/**.")
            } else {
                segments.append(.glob(part))
            }
        }

        let compiled = Compiled(segments: segments)
        if matchesEverything(compiled) {
            return .failure("That pattern would exclude everything.")
        }
        return .success(CompiledPattern(display: text, compiled: compiled))
    }

    private static func matchesEverything(_ pattern: Compiled) -> Bool {
        ["a", "Archive", ".gitignore", "src/main.swift"].allSatisfy { probe in
            let parts = pathComponents(probe)
            var prefix: [String] = []
            for part in parts {
                prefix.append(part)
                if matches(prefix, pattern: pattern) {
                    return true
                }
            }
            return false
        }
    }

    private static func pathComponents(_ relativePath: String) -> [String] {
        var text = relativePath.replacingOccurrences(of: "\\", with: "/")
        while text.hasPrefix("./") {
            text.removeFirst(2)
        }
        while text.hasPrefix("/") {
            text.removeFirst()
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            .filter { $0 != "." }
    }

    /// True when `pattern` matches the whole component list, starting at any component.
    private static func matches(_ components: [String], pattern: Compiled) -> Bool {
        guard !components.isEmpty else { return false }
        for start in components.indices {
            if match(components, start, pattern.segments, 0) {
                return true
            }
        }
        return false
    }

    private static func match(
        _ components: [String],
        _ index: Int,
        _ segments: [Compiled.Segment],
        _ segmentIndex: Int
    ) -> Bool {
        if segmentIndex == segments.count {
            return index == components.count
        }
        switch segments[segmentIndex] {
        case .globstar:
            if match(components, index, segments, segmentIndex + 1) {
                return true
            }
            var next = index
            while next < components.count {
                next += 1
                if match(components, next, segments, segmentIndex + 1) {
                    return true
                }
            }
            return false
        case .glob(let glob):
            guard index < components.count, componentMatches(glob, components[index]) else {
                return false
            }
            return match(components, index + 1, segments, segmentIndex + 1)
        }
    }

    private static func componentMatches(_ glob: String, _ component: String) -> Bool {
        if !glob.contains("*"), !glob.contains("?") {
            return sameName(glob, component)
        }
        return globMatches(folded(glob), folded(component))
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        folded(lhs) == folded(rhs)
    }

    /// Case-fold and compose so `Café` matches `café`, including filenames stored decomposed.
    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// `*` is any run of characters. `?` is one character. `[`, `]`, and other letters stay literal.
    private static func globMatches(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern)
        let text = Array(text)
        var patternIndex = 0
        var textIndex = 0
        var starPattern: Int?
        var starText = 0

        while textIndex < text.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starPattern = patternIndex
                starText = textIndex
                patternIndex += 1
            } else if let star = starPattern {
                patternIndex = star + 1
                starText += 1
                textIndex = starText
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    private static func expandToolPattern(_ display: String) -> [String] {
        var bases = [display]
        if !display.hasPrefix("*") {
            bases.append("*/\(display)")
            bases.append("**/\(display)")
        } else if !display.contains("/") {
            bases.append("*/\(display)")
            bases.append("**/\(display)")
        }
        var all = bases
        for base in bases where !base.hasSuffix("/*") {
            all.append("\(base)/*")
        }
        return all
    }
}
