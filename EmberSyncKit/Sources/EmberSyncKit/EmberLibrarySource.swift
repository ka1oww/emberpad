#if os(macOS)
import Foundation

/// Reads the iPad library straight from the Ember main folder (`~/Documents/Ember Projects`), read-only.
///
/// Only finished Student/Teacher pairs are listed, and "finished" is decided by publication records and SHA-256
/// values alone, never by a file or folder name:
///
/// - **R1, paper.** A project with `paper.json` is finished when `audit/visual/<build>.json` has `status: pass` and
///   its `student_pdf_sha256` and `teacher_pdf_sha256` equal the bytes of `artifacts/<build>/student.pdf` and
///   `teacher.pdf`. The newest such record wins, by `reviewed_at`, then by the build record's `finished_at`.
/// - **R2, tutorial.** A project with `tutorial.tex` (and no `paper.json`) is finished when `artifacts/latest.json`
///   names a build whose two copies match the hashes it records, in either the `{student, teacher}` or the
///   `{pdfs: {student: {sha256}, teacher: {sha256}}}` schema. An H2 Math tutorial also needs a sign-off record under
///   `evidence/` bound to that build id and both hashes, otherwise it is a miss.
///
/// Pairing is structural: both copies come from one build directory, and each copy's role is the record key its
/// hash matched. Nothing is ever written below the root. A project that no longer yields a pair keeps its previous
/// entries ("no update"); the reader never removes a paper from the iPad.
public struct EmberLibrarySource: Sendable {
    /// The subject folders the Ember publisher knows, plus H2 Econs. Every other top-level folder is skipped.
    public static let subjectFolders = ["A-Math", "H2 Chemistry", "H2 Econs", "H2 Math", "H2 Physics", "Pure Chemistry",
                                        "Pure Physics"]
    /// Subjects whose tutorials also need a captain sign-off bound to the build `latest.json` names.
    public static let signoffSubjects: Set<String> = ["H2 Math"]
    /// Shown for an entry with no class tag: a nil `classTag` means the copy belongs under every class.
    public static let allClassesLabel = "All classes"

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Ember Projects", isDirectory: true)
    }

    public let root: URL
    public let aliases: ClassAliasTable
    // TODO(emberpad-library-source-scope Q1): the captain has not decided whether the 12 published papers that no
    // longer have a finished pair in Ember Projects should come from the main Drive EMBER folder through the
    // publisher registry. Until he picks it, no fallback is configured and v1 lists Ember Projects pairs only.
    public let fallback: (any LibraryFallbackSource)?

    public init(root: URL = Self.defaultRoot, aliases: ClassAliasTable = .empty, fallback: (any LibraryFallbackSource)? = nil) {
        self.root = root
        self.aliases = aliases
        self.fallback = fallback
    }

    /// Walks the root and returns a version-2 manifest plus the miss list. `previous` is the manifest last
    /// delivered: any of its papers that is not found again is carried forward unchanged.
    public func read(previous: Manifest? = nil, generatedAt: Date = Date()) throws -> LibrarySnapshot {
        var reader = Reader(root: root, aliases: aliases)
        var found: [LibraryPair] = []
        var misses: [LibraryMiss] = []
        var unrecorded: [String] = []
        var seenKeys: Set<PaperKey> = []

        for subject in Self.subjectFolders {
            for project in reader.directories(in: root.appendingPathComponent(subject, isDirectory: true)) {
                let name = project.lastPathComponent
                let label = subject + "/" + name
                switch reader.examine(project: project, subject: subject) {
                case .pair(let pair): found.append(pair); seenKeys.insert(pair.paperKey)
                case .miss(let reason, let detail, let key):
                    misses.append(LibraryMiss(project: label, reason: reason, detail: detail))
                    if let key { seenKeys.insert(key) }
                case .unrecorded: unrecorded.append(label)
                }
            }
        }
        if let fallback {
            let present = Set(found.map(\.paperKey))
            found += try fallback.pairs(excluding: present).filter { !present.contains($0.paperKey) }
        }

        let withheld = aliases.withheldTerms + reader.withheldTerms + found.flatMap(\.withheldTerms)
        var pairs = Gate.uniqueKeys(found, misses: &misses)
        pairs = Gate.privacy(pairs, terms: withheld, misses: &misses)

        var retained: [LibraryRetained] = []
        var files = pairs.flatMap { [$0.student.entry, $0.teacher.entry] }
        if let previous {
            let current = Set(pairs.map(\.paperKey))
            let carried = Dictionary(grouping: previous.files.filter { $0.paperKey.map { !current.contains($0) } ?? false },
                                     by: { $0.paperKey! })
            let occupied = Set(files.map(\.source))
            for (key, entries) in carried.sorted(by: { $0.key < $1.key }) {
                let strings = entries.flatMap { [$0.source.key, $0.title, $0.subject] + ($0.classTag.map { [$0] } ?? []) } + [key.rawValue]
                if let term = Gate.firstWithheld(in: strings, terms: withheld) {
                    misses.append(LibraryMiss(project: key.rawValue, reason: .privacyWithheld,
                                              detail: "previous entry carries a withheld term (\(term.count) characters)"))
                    continue
                }
                guard entries.allSatisfy({ !occupied.contains($0.source) }) else {
                    misses.append(LibraryMiss(project: key.rawValue, reason: .duplicatePaperKey,
                                              detail: "previous entry's path is now used by another paper"))
                    continue
                }
                retained.append(LibraryRetained(paperKey: key, reason: seenKeys.contains(key) ? .noLongerFinished : .sourceVanished,
                                                entries: entries))
                files += entries
            }
        }
        files = Gate.crossRole(files, retained: &retained, pairs: &pairs, misses: &misses,
                               previous: previous?.files ?? [], withheldTerms: withheld)
        files = Gate.finalPrivacy(files, pairs: &pairs, retained: &retained, terms: withheld, misses: &misses)

        let manifest = try Manifest(version: 2, generatedAt: generatedAt, files: files)
        return LibrarySnapshot(manifest: manifest, pairs: pairs, misses: misses.sorted { ($0.project, $0.reason.rawValue) < ($1.project, $1.reason.rawValue) },
                               retained: retained, unrecordedProjects: unrecorded)
    }
}

/// An extension point for copies that live outside Ember Projects (open captain question
/// emberpad-library-source-scope Q1). A fallback pair never replaces a pair found under the root, and passes the
/// same duplicate-key, privacy and cross-role gates.
public protocol LibraryFallbackSource: Sendable {
    func pairs(excluding paperKeys: Set<PaperKey>) throws -> [LibraryPair]
}

/// One copy of a pair: the manifest entry the iPad sees, and the local file it was read from (Mac only).
public struct LibraryCopy: Equatable, Sendable {
    public let entry: ManifestEntry
    public let fileURL: URL
    public init(entry: ManifestEntry, fileURL: URL) { self.entry = entry; self.fileURL = fileURL }
}

public struct LibraryPair: Equatable, Sendable {
    public enum Rule: String, Sendable { case paper, tutorial, fallback }
    public let paperKey: PaperKey
    /// Local only: the `<Subject>/<Project>` label the pair was read from.
    public let project: String
    public let rule: Rule
    /// Local only: the build directory both copies came from. It can carry a person's name, so it is never put in
    /// the manifest.
    public let buildID: String
    public let student: LibraryCopy
    public let teacher: LibraryCopy
    /// Terms that must not reach the iPad, found while naming this pair.
    let withheldTerms: [String]
    public var bytes: Int64 { student.entry.size + teacher.entry.size }

    public init(paperKey: PaperKey, project: String, rule: Rule, buildID: String, student: LibraryCopy, teacher: LibraryCopy) throws {
        try self.init(paperKey: paperKey, project: project, rule: rule, buildID: buildID, student: student, teacher: teacher,
                      withheldTerms: [])
    }

    init(paperKey: PaperKey, project: String, rule: Rule, buildID: String, student: LibraryCopy, teacher: LibraryCopy,
         withheldTerms: [String]) throws {
        guard student.entry.role == .student, teacher.entry.role == .teacher,
              student.entry.paperKey == paperKey, teacher.entry.paperKey == paperKey else { throw LibraryError.invalidManifest }
        self.paperKey = paperKey
        self.project = project
        self.rule = rule
        self.buildID = buildID
        self.student = student
        self.teacher = teacher
        self.withheldTerms = withheldTerms
    }
}

/// A project that has a publication record but yields no finished pair, or a pair the gates held back.
/// `project` is the local `<Subject>/<Project>` label; the miss list stays on the Mac.
public struct LibraryMiss: Equatable, Sendable {
    public enum Reason: String, Sendable, CaseIterable {
        case paperNotSignedOff = "paper-not-signed-off"
        case tutorialPointerMissing = "tutorial-pointer-missing"
        case tutorialPointerUnreadable = "tutorial-pointer-unreadable"
        case tutorialHashMismatch = "tutorial-hash-mismatch"
        case mathTutorialUnsigned = "math-tutorial-unsigned"
        case identicalCopies = "identical-copies"
        case studentMatchesTeacher = "student-matches-a-teacher-copy"
        case privacyWithheld = "privacy-withheld"
        case duplicatePaperKey = "duplicate-paper-key"
        case invalidRecord = "invalid-record"
    }
    public let project: String
    public let reason: Reason
    public let detail: String
}

/// A paper kept from the previous manifest because it was not found again. Its entries are listed unchanged.
public struct LibraryRetained: Equatable, Sendable {
    public enum Reason: String, Sendable { case sourceVanished = "source-vanished", noLongerFinished = "no-longer-finished" }
    public let paperKey: PaperKey
    public let reason: Reason
    public let entries: [ManifestEntry]
}

public struct LibrarySnapshot: Equatable, Sendable {
    /// Version 2: found pairs first, then retained entries.
    public let manifest: Manifest
    public let pairs: [LibraryPair]
    public let misses: [LibraryMiss]
    public let retained: [LibraryRetained]
    /// Local `<Subject>/<Project>` labels with neither `paper.json` nor `tutorial.tex`. Not imported.
    public let unrecordedProjects: [String]
    public var pairBytes: Int64 { pairs.reduce(0) { $0 + $1.bytes } }
}

/// Maps a project-name prefix to a class tag, for prefixes such as a personal name followed by "Sec 3".
/// The real table is personal data and lives outside the repository, at `defaultURL`:
///
/// ```json
/// {"schema": "emberpad.class-aliases/v1", "aliases": {"<prefix>": "<class>"}, "withhold": ["<term>"]}
/// ```
///
/// Any `withhold` term, and every word of a personal-name-shaped prefix, must never reach the manifest: a pair
/// whose manifest strings would still carry one is held back as a miss.
public struct ClassAliasTable: Equatable, Sendable {
    public static let schema = "emberpad.class-aliases/v1"
    public static let empty = ClassAliasTable()
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EmberPad/class-aliases.json", isDirectory: false)
    }

    public let aliases: [String: String]
    public let withheldTerms: [String]
    public let skippedAliasCount: Int

    private init() { aliases = [:]; withheldTerms = []; skippedAliasCount = 0 }

    public init(aliases: [String: String], withheldTerms: [String] = []) throws {
        guard aliases.keys.allSatisfy(Publication.isValidLabel),
              withheldTerms.allSatisfy(Publication.isValidLabel),
              Set(aliases.keys.map { $0.lowercased() }).count == aliases.count else { throw LibraryError.invalidManifest }
        self.aliases = aliases.filter { ClassResolver.isClassTag($0.value) }
        self.skippedAliasCount = aliases.count - self.aliases.count
        self.withheldTerms = withheldTerms
            + aliases.keys.flatMap { ClassResolver.aliasNameWords($0) }
            .filter { term in !withheldTerms.contains { $0.caseInsensitiveCompare(term) == .orderedSame } }
    }

    /// A missing file is an empty table. A present but malformed file throws, so a broken table is noticed.
    public static func load(from url: URL = defaultURL) throws -> ClassAliasTable {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              object["schema"] as? String == schema,
              Set(object.keys).isSubset(of: ["schema", "aliases", "withhold"]),
              let aliases = (object["aliases"] ?? [String: String]()) as? [String: String],
              let withhold = (object["withhold"] ?? [String]()) as? [String]
        else { throw LibraryError.invalidManifest }
        return try ClassAliasTable(aliases: aliases, withheldTerms: withhold)
    }
}

// MARK: - Class from the project-name prefix

struct ClassResolution: Equatable {
    /// Nil is the "All classes" bucket.
    let classTag: String?
    /// The project name with any personal prefix replaced by its class or removed.
    let displayName: String
    let withheldTerms: [String]
    /// Applies the same prefix rewrite to another string, such as a publisher display name.
    let rewrite: @Sendable (String) -> String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.classTag == rhs.classTag && lhs.displayName == rhs.displayName && lhs.withheldTerms == rhs.withheldTerms
    }
}

enum ClassResolver {
    /// Class prefixes that already are class names, matched case-insensitively and reported in this spelling.
    static let classCodes = ["MI PU1", "MI PU2", "MI PU3", "YIJC JC1", "YIJC JC2", "NYJC-EJC JC1", "NYJC-EJC JC2",
                             "SEC 1", "SEC 2", "SEC 3", "SEC 4"]

    static func resolve(_ name: String, aliases: ClassAliasTable) -> ClassResolution {
        let personalSegments = personalNameSegments(name, aliases: aliases.aliases.keys.map { $0 })
        if !personalSegments.isEmpty {
            let cleanedName = removingPersonalNameSegments(name, aliases: aliases.aliases.keys.map { $0 })
            let safe = resolve(cleanedName, aliases: aliases)
            let rewrite: @Sendable (String) -> String = { value in
                safe.rewrite(removingPersonalNameSegments(value, aliases: aliases.aliases.keys.map { $0 }))
            }
            return ClassResolution(classTag: nil, displayName: rewrite(name),
                                   withheldTerms: personalSegments.flatMap { nameWords(String(name[$0])) } + safe.withheldTerms,
                                   rewrite: rewrite)
        }

        if let section = sectionPrefix(name, aliases: aliases.aliases.keys.map { $0 }) {
            let prefixWords = normalizedWords(section.prefix)
            let fullWords = normalizedWords(section.fullPrefix)
            if let alias = aliases.aliases.keys.sorted().first(where: {
                normalizedWords($0) == fullWords || normalizedWords($0) == prefixWords
            }), let tag = aliases.aliases[alias] {
                let replacementPrefix = normalizedWords(alias) == fullWords ? section.fullPrefix : section.prefix
                let rewrite: @Sendable (String) -> String = { replacingWordPrefix($0, replacementPrefix, with: tag) }
                return ClassResolution(classTag: tag, displayName: rewrite(name), withheldTerms: aliasNameWords(alias), rewrite: rewrite)
            }
            if let code = classCodes.first(where: { normalizedWords($0) == fullWords || normalizedWords($0) == prefixWords }) {
                return ClassResolution(classTag: code, displayName: name, withheldTerms: [], rewrite: { $0 })
            }
            let rewrite: @Sendable (String) -> String = { replacingWordPrefix($0, section.prefix, with: nil) }
            return ClassResolution(classTag: nil, displayName: rewrite(name),
                                   withheldTerms: nameWords(section.prefix), rewrite: rewrite)
        }

        // 1. Alias table, longest matching prefix first.
        if let alias = aliases.aliases.keys.filter({ hasWordPrefix(name, $0) }).max(by: { $0.count < $1.count }),
           let tag = aliases.aliases[alias] {
            let withheld = aliasNameWords(alias)
            let rewrite: @Sendable (String) -> String = { replacingWordPrefix($0, alias, with: tag) }
            return ClassResolution(classTag: tag, displayName: rewrite(name), withheldTerms: withheld, rewrite: rewrite)
        }
        // 2. A class code.
        if let code = classCodes.first(where: { hasWordPrefix(name, $0) }) {
            return ClassResolution(classTag: code, displayName: name, withheldTerms: [], rewrite: { $0 })
        }
        // 3. A personal-name-shaped prefix with no alias: the name is dropped and the copy goes to every class.
        if let prefix = personalNameShape(name) {
            let rewrite: @Sendable (String) -> String = { replacingWordPrefix($0, prefix, with: nil) }
            return ClassResolution(classTag: nil, displayName: rewrite(name),
                                   withheldTerms: nameWords(prefix), rewrite: rewrite)
        }
        return ClassResolution(classTag: nil, displayName: name, withheldTerms: [], rewrite: { $0 })
    }

    /// The complete prefix before `Sec <1-4>` or `S<1-4>`, unless that prefix is already a class code.
    static func personalNameShape(_ name: String) -> String? {
        guard let segment = personalNameSegments(name, aliases: []).first else { return nil }
        return String(name[segment])
    }

    static func aliasNameWords(_ alias: String) -> [String] {
        let words = nameWords(alias)
        let withheld = personalNameShape(alias).map(nameWords) ?? words
        guard let code = classCodes.filter({ hasWordPrefix(alias, $0) }).max(by: { $0.count < $1.count }) else {
            return withheld
        }
        return Array(withheld.dropFirst(min(nameWords(code).count, withheld.count)))
    }

    static func isClassTag(_ tag: String) -> Bool {
        guard Publication.isValidLabel(tag) else { return false }
        if classCodes.contains(where: { $0 == tag }) { return true }
        let words = tag.split(separator: " ", omittingEmptySubsequences: false)
        guard (1...3).contains(words.count) else { return false }
        return words.allSatisfy { word in
            (1...12).contains(word.count) && word.unicodeScalars.enumerated().allSatisfy { index, scalar in
                (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 48 && scalar.value <= 57) ||
                    (index > 0 && scalar == "-")
            } && word.first.map { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") } == true
        }
    }

    private static func sectionPrefix(_ name: String, aliases: [String]) -> (prefix: String, fullPrefix: String)? {
        guard personalNameSegments(name, aliases: aliases).isEmpty else { return nil }
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let token = words.indices.first(where: { index in
            let word = words[index].lowercased()
            if word == "sec" {
                return words.index(after: index) < words.endIndex &&
                    ["1", "2", "3", "4"].contains(String(words[words.index(after: index)]))
            }
            return ["s1", "s2", "s3", "s4"].contains(word)
        }) else { return nil }
        let prefix = String(name[..<words[token].startIndex]).trimmingCharacters(in: .whitespaces)
        let tokenEnd = words[token].count == 2 && words[token].uppercased().hasPrefix("S")
            ? words[token].endIndex
            : words[words.index(after: token)].endIndex
        let fullPrefix = String(name[..<tokenEnd]).trimmingCharacters(in: .whitespaces)
        return (prefix, fullPrefix)
    }

    private static func normalizedWords(_ value: String) -> String {
        nameWords(value).joined(separator: " ").uppercased()
    }

    static func containsPersonalNameShape(_ value: String) -> Bool {
        value.split(separator: "/", omittingEmptySubsequences: false)
            .contains { !personalNameSegments(String($0), aliases: []).isEmpty }
    }

    private static func personalNameSegments(_ name: String, aliases: [String]) -> [Range<String.Index>] {
        let words = name.split(whereSeparator: \.isWhitespace)
        var markers: [(start: String.Index, end: String.Index)] = []
        var index = 0
        while index < words.count {
            let word = words[index].lowercased()
            if word == "sec", index + 1 < words.count, ["1", "2", "3", "4"].contains(String(words[index + 1])) {
                markers.append((words[index].startIndex, words[index + 1].endIndex))
                index += 2
            } else if ["s1", "s2", "s3", "s4"].contains(word) {
                markers.append((words[index].startIndex, words[index].endIndex))
                index += 1
            } else {
                index += 1
            }
        }

        var previousEnd = name.startIndex
        var personal: [Range<String.Index>] = []
        for marker in markers {
            let segment = name[previousEnd..<marker.start].trimmingCharacters(in: .whitespaces)
            let token = name[marker.start..<marker.end]
            let normalized = normalizedWords(segment)
            let full = normalizedWords(String(segment) + " " + String(token))
            let allowed = segment.isEmpty || classCodes.contains { normalizedWords($0) == normalized } ||
                aliases.contains { let alias = normalizedWords($0); return alias == normalized || alias == full }
            if !allowed, let range = name.range(of: segment, range: previousEnd..<marker.start) {
                personal.append(range)
            }
            previousEnd = marker.end
        }
        return personal
    }

    private static func removingPersonalNameSegments(_ name: String, aliases: [String]) -> String {
        var result = name
        for range in personalNameSegments(name, aliases: aliases).reversed() {
            result.replaceSubrange(range, with: "")
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nameWords(_ name: String) -> [String] {
        name.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func hasWordPrefix(_ text: String, _ prefix: String) -> Bool {
        guard text.count >= prefix.count, text.prefix(prefix.count).lowercased() == prefix.lowercased() else { return false }
        return text.count == prefix.count || text.dropFirst(prefix.count).first?.isWhitespace == true
    }

    static func replacingWordPrefix(_ text: String, _ prefix: String, with replacement: String?) -> String {
        guard hasWordPrefix(text, prefix) else { return text }
        let rest = text.dropFirst(prefix.count).drop(while: { $0.isWhitespace })
        guard let replacement else { return String(rest) }
        return rest.isEmpty ? replacement : replacement + " " + rest
    }
}

// MARK: - Gates applied to every pair before it reaches the manifest

enum Gate {
    /// Two projects that would show under one paper key are both held back rather than guessed between.
    static func uniqueKeys(_ pairs: [LibraryPair], misses: inout [LibraryMiss]) -> [LibraryPair] {
        let paths = pairs.flatMap { [$0.student.entry.source, $0.teacher.entry.source] }
        let pathCounts = Dictionary(paths.map { ($0, 1) }, uniquingKeysWith: +)
        let keyCounts = Dictionary(pairs.map { ($0.paperKey, 1) }, uniquingKeysWith: +)
        return pairs.filter { pair in
            let unique = keyCounts[pair.paperKey] == 1 &&
                pathCounts[pair.student.entry.source] == 1 && pathCounts[pair.teacher.entry.source] == 1
            if !unique {
                misses.append(LibraryMiss(project: pair.project, reason: .duplicatePaperKey,
                                          detail: "another project shows under the same paper key or path"))
            }
            return unique
        }
    }

    static func privacy(_ pairs: [LibraryPair], terms: [String], misses: inout [LibraryMiss]) -> [LibraryPair] {
        pairs.filter { pair in
            let entries = [pair.student.entry, pair.teacher.entry]
            guard passesPrivacy(entries, key: pair.paperKey, terms: terms) else {
                misses.append(LibraryMiss(project: pair.project, reason: .privacyWithheld,
                                          detail: "a manifest string failed the final privacy check"))
                return false
            }
            return true
        }
    }

    static func finalPrivacy(_ files: [ManifestEntry], pairs: inout [LibraryPair], retained: inout [LibraryRetained],
                             terms: [String], misses: inout [LibraryMiss]) -> [ManifestEntry] {
        let groups = Dictionary(grouping: files, by: \.paperKey)
        let blocked = Set(groups.compactMap { key, entries -> PaperKey? in
            guard passesPrivacy(entries, key: key, terms: terms) else {
                misses.append(LibraryMiss(project: key?.rawValue ?? "manifest-entry", reason: .privacyWithheld,
                                          detail: "a manifest string failed the final privacy check"))
                return key
            }
            return nil
        })
        pairs.removeAll { blocked.contains($0.paperKey) }
        retained.removeAll { blocked.contains($0.paperKey) }
        return files.filter { entry in
            guard let key = entry.paperKey else { return false }
            return !blocked.contains(key)
        }
    }

    private static func passesPrivacy(_ entries: [ManifestEntry], key: PaperKey?, terms: [String]) -> Bool {
        let strings = entries.flatMap { entry in
            [entry.source.key, entry.source.relativePath, entry.title, entry.subject] + (entry.classTag.map { [$0] } ?? [])
        } + (key.map { [$0.rawValue] } ?? [])
        let invalidClassTag = entries.contains { $0.classTag.map { !ClassResolver.isClassTag($0) } ?? false }
        return !invalidClassTag && !strings.contains(where: ClassResolver.containsPersonalNameShape) &&
            firstWithheld(in: strings, terms: terms) == nil
    }

    /// Whole-word, case-insensitive search.
    static func firstWithheld(in strings: [String], terms: [String]) -> String? {
        terms.first { term in
            strings.contains { string in
                var range = string.startIndex..<string.endIndex
                while let found = string.range(of: term, options: [.caseInsensitive], range: range) {
                    let before = found.lowerBound == string.startIndex ? nil : string[string.index(before: found.lowerBound)]
                    let after = found.upperBound == string.endIndex ? nil : string[found.upperBound]
                    if !(before?.isLetter ?? false) && !(before?.isNumber ?? false) &&
                        !(after?.isLetter ?? false) && !(after?.isNumber ?? false) { return true }
                    range = found.upperBound..<string.endIndex
                }
                return false
            }
        }
    }

    /// A Student entry whose bytes equal any Teacher copy in the library would show answers to students, so the
    /// whole paper it belongs to is held back.
    static func crossRole(_ files: [ManifestEntry], retained: inout [LibraryRetained], pairs: inout [LibraryPair],
                          misses: inout [LibraryMiss], previous: [ManifestEntry], withheldTerms: [String]) -> [ManifestEntry] {
        let teacherHashes = Set(files.filter { $0.role == .teacher }.map(\.sha256))
        let blocked = Set(files.filter { $0.role == .student && teacherHashes.contains($0.sha256) }.compactMap(\.paperKey))
        guard !blocked.isEmpty else { return files }
        let blockedPairs = pairs.filter { blocked.contains($0.paperKey) }
        for key in blocked.sorted() {
            misses.append(LibraryMiss(project: pairs.first { $0.paperKey == key }?.project ?? key.rawValue, reason: .studentMatchesTeacher,
                                      detail: "a Student copy has the same bytes as a Teacher copy"))
        }
        pairs.removeAll { blocked.contains($0.paperKey) }
        retained.removeAll { blocked.contains($0.paperKey) }
        var remaining = files.filter { !($0.paperKey.map(blocked.contains) ?? false) }
        var previousByKey: [PaperKey: [ManifestEntry]] = [:]
        for entry in previous {
            if let key = entry.paperKey { previousByKey[key, default: []].append(entry) }
        }
        let occupied = Set(remaining.map(\.source))
        let candidates = blockedPairs.compactMap { pair -> (PaperKey, [ManifestEntry])? in
            guard let entries = previousByKey[pair.paperKey], entries.count == 2,
                  entries.filter({ $0.role == .student }).count == 1,
                  entries.filter({ $0.role == .teacher }).count == 1,
                  entries.allSatisfy({ $0.paperKey == pair.paperKey && !occupied.contains($0.source) }),
                  Gate.firstWithheld(in: entries.flatMap {
                      [$0.source.key, $0.title, $0.subject] + ($0.classTag.map { [$0] } ?? [])
                  } + [pair.paperKey.rawValue], terms: withheldTerms) == nil else { return nil }
            return (pair.paperKey, entries)
        }
        let candidateFiles = candidates.flatMap(\.1)
        for (key, entries) in candidates {
            guard let student = entries.first(where: { $0.role == .student }),
                  let teacher = entries.first(where: { $0.role == .teacher }) else { continue }
            let others = remaining + candidateFiles.filter { $0.paperKey != key }
            let otherStudentHashes = Set(others.filter { $0.role == .student }.map(\.sha256))
            let otherTeacherHashes = Set(others.filter { $0.role == .teacher }.map(\.sha256))
            guard student.sha256 != teacher.sha256,
                  !otherTeacherHashes.contains(student.sha256), !otherStudentHashes.contains(teacher.sha256) else { continue }
            retained.append(LibraryRetained(paperKey: key, reason: .noLongerFinished, entries: entries))
            remaining += entries
        }
        return remaining
    }
}

// MARK: - Reading one project

private struct Reader {
    // The real Ember Projects library uses these G11 versions; any other or missing schema is rejected.
    private static let visualSignoffSchemas: Set<String> = [
        "ember.visual-signoff/v1", "ember.visual-signoff/v3", "ember.visual-signoff/v4", "ember.visual-signoff/v5"
    ]
    private static let paperSubjectFolders = [
        "amath": "A-Math", "h2_chem": "H2 Chemistry", "h2_math": "H2 Math", "h2_physics": "H2 Physics",
        "pure_chem": "Pure Chemistry", "h2_econs": "H2 Econs", "pure_physics": "Pure Physics"
    ]

    enum Outcome {
        case pair(LibraryPair)
        case miss(LibraryMiss.Reason, String, PaperKey?)
        case unrecorded
    }

    let root: URL
    let aliases: ClassAliasTable
    let fileManager = FileManager.default
    var hashes: [String: ContentHash] = [:]
    var withheldTerms: [String] = []

    init(root: URL, aliases: ClassAliasTable) {
        self.root = root
        self.aliases = aliases
    }

    /// Real (non-symlink) subdirectories, sorted by name. A missing folder has none.
    func directories(in folder: URL) -> [URL] {
        guard isDirectory(folder),
              let children = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                  options: [.skipsHiddenFiles]) else { return [] }
        return children.filter(isDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    mutating func examine(project: URL, subject: String) -> Outcome {
        let naming = ClassResolver.resolve(project.lastPathComponent, aliases: aliases)
        withheldTerms += naming.withheldTerms
        let key = try? PaperKey(rawValue: subject + "/" + naming.displayName)
        if isFile(project.appendingPathComponent("paper.json")) {
            return paper(project: project, subject: subject, naming: naming, key: key)
        }
        if isFile(project.appendingPathComponent("tutorial.tex")) {
            return tutorial(project: project, subject: subject, naming: naming, key: key)
        }
        return .unrecorded
    }

    // R1
    private mutating func paper(project: URL, subject: String, naming: ClassResolution, key: PaperKey?) -> Outcome {
        guard let paper = json(project.appendingPathComponent("paper.json")) else {
            return .miss(.invalidRecord, "paper.json is not a JSON object", key)
        }
        guard let details = paper["paper"] as? [String: Any],
              let title = details["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let paperSubject = details["subject"] as? String, Self.paperSubjectFolders[paperSubject] == subject,
              let output = paper["output"] as? [String: Any],
              let studentOutput = output["student_pdf"] as? String,
              !studentOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let teacherOutput = output["teacher_pdf"] as? String,
              !teacherOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .miss(.invalidRecord, "paper.json is incomplete or its subject does not match the project folder", key)
        }
        struct Candidate { let reviewedAt: Date; let finishedAt: Date; let build: String }
        var candidates: [Candidate] = []
        var seen: Set<String> = []
        var invalidBuildRecord = false
        let audit = project.appendingPathComponent("audit/visual", isDirectory: true)
        let records = hasRealDirectoryChain(project: project, relativePath: "audit/visual")
            ? (try? fileManager.contentsOfDirectory(at: audit, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                             options: [.skipsHiddenFiles])) ?? []
            : []
        for record in records.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where record.pathExtension == "json" && isFile(record) {
            guard let signoff = json(record), let schema = signoff["schema_version"] as? String,
                  Self.visualSignoffSchemas.contains(schema), signoff["status"] as? String == "pass",
                  let build = signoff["build_id"] as? String, Self.isSafeComponent(build), !seen.contains(build),
                  let reviewedAt = Self.timestamp(signoff["reviewed_at"] as? String),
                  let student = signoff["student_pdf_sha256"] as? String, let teacher = signoff["teacher_pdf_sha256"] as? String,
                  matches(project: project, build: build, student: student, teacher: teacher) else { continue }
            guard let buildRecord = json(project.appendingPathComponent("artifacts/\(build)/build-record.json")),
                  let finishedAt = Self.timestamp(buildRecord["finished_at"] as? String) else {
                invalidBuildRecord = true
                continue
            }
            seen.insert(build)
            candidates.append(Candidate(reviewedAt: reviewedAt, finishedAt: finishedAt, build: build))
        }
        guard let pick = candidates.max(by: { lhs, rhs in
            if lhs.reviewedAt != rhs.reviewedAt { return lhs.reviewedAt < rhs.reviewedAt }
            if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt < rhs.finishedAt }
            return lhs.build < rhs.build
        }) else {
            if invalidBuildRecord {
                return .miss(.invalidRecord, "a hash-matched candidate has no valid build finish timestamp", key)
            }
            return .miss(.paperNotSignedOff, "no passing audit/visual record whose two hashes match its build's copies", key)
        }
        func displayName(_ file: String, fallback: String) -> String {
            guard file.lowercased().hasSuffix(".pdf"), file.count > 4 else { return fallback }
            return naming.rewrite(String(file.dropLast(4))).trimmingCharacters(in: .whitespaces)
        }
        let studentTitle = displayName(studentOutput, fallback: naming.rewrite(title))
        let teacherTitle = displayName(teacherOutput, fallback: studentTitle + " (Teacher)")
        return makePair(project: project, subject: subject, naming: naming, key: key, rule: .paper, build: pick.build,
                        titles: (studentTitle, teacherTitle))
    }

    // R2
    private mutating func tutorial(project: URL, subject: String, naming: ClassResolution, key: PaperKey?) -> Outcome {
        let pointerURL = project.appendingPathComponent("artifacts/latest.json")
        guard hasRealDirectoryChain(project: project, relativePath: "artifacts"), isFile(pointerURL) else {
            return .miss(.tutorialPointerMissing, "no artifacts/latest.json", key)
        }
        guard let pointer = json(pointerURL), let build = pointer["build_id"] as? String, Self.isSafeComponent(build),
              let recorded = Self.pointerHashes(pointer) else {
            return .miss(.tutorialPointerUnreadable, "artifacts/latest.json names no build with hashes in a known schema", key)
        }
        guard matches(project: project, build: build, student: recorded.student, teacher: recorded.teacher) else {
            return .miss(.tutorialHashMismatch, "artifacts/latest.json hashes do not match its build's copies", key)
        }
        if EmberLibrarySource.signoffSubjects.contains(subject),
           !hasSignoff(project: project, build: build, student: recorded.student, teacher: recorded.teacher) {
            return .miss(.mathTutorialUnsigned, "no evidence sign-off bound to the build and both hashes", key)
        }
        return makePair(project: project, subject: subject, naming: naming, key: key, rule: .tutorial, build: build,
                        titles: (naming.displayName, naming.displayName + " (Teacher)"))
    }

    /// `{student, teacher}` (string hashes) or `{pdfs: {student: {sha256}, teacher: {sha256}}}`. Both present must agree.
    static func pointerHashes(_ pointer: [String: Any]) -> (student: String, teacher: String)? {
        let flat = (pointer["student"] as? String).flatMap { s in (pointer["teacher"] as? String).map { (s, $0) } }
        let pdfs = pointer["pdfs"] as? [String: Any]
        let nested = ((pdfs?["student"] as? [String: Any])?["sha256"] as? String).flatMap { s in
            ((pdfs?["teacher"] as? [String: Any])?["sha256"] as? String).map { (s, $0) }
        }
        switch (flat, nested) {
        case let (a?, b?): return a.0.lowercased() == b.0.lowercased() && a.1.lowercased() == b.1.lowercased() ? a : nil
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// A JSON object under `evidence/` with the required schema, build, hashes and non-empty verbatim approval.
    private mutating func hasSignoff(project: URL, build: String, student: String, teacher: String) -> Bool {
        let evidence = project.appendingPathComponent("evidence", isDirectory: true)
        guard hasRealDirectoryChain(project: project, relativePath: "evidence"), let walker = fileManager.enumerator(
            at: evidence, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        else { return false }
        for case let url as URL in walker where url.pathExtension == "json" && isFile(url) &&
            hasRealDirectoryChain(project: project, relativePath: relativeDirectory(of: url, below: project)) {
            guard let record = json(url), record["schema"] as? String == "ember.math-tutorial-signoff/v1",
                  record["build_id"] as? String == build,
                  let verbatim = record["verbatim"] as? String,
                  !verbatim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            for field in ["pdf_sha256", "pdfs"] {
                guard let map = record[field] as? [String: Any] else { continue }
                func hash(_ role: String) -> String? { map[role] as? String ?? (map[role] as? [String: Any])?["sha256"] as? String }
                if let s = hash("student"), let t = hash("teacher"), s.lowercased() == student.lowercased(),
                   t.lowercased() == teacher.lowercased() { return true }
            }
        }
        return false
    }

    private mutating func makePair(project: URL, subject: String, naming: ClassResolution, key: PaperKey?, rule: LibraryPair.Rule,
                                   build: String, titles: (student: String, teacher: String)) -> Outcome {
        let directory = project.appendingPathComponent("artifacts/\(build)", isDirectory: true)
        let studentURL = directory.appendingPathComponent("student.pdf"), teacherURL = directory.appendingPathComponent("teacher.pdf")
        do {
            guard let key, hasRealDirectoryChain(project: project, relativePath: "artifacts/\(build)") else {
                throw LibraryError.invalidManifest
            }
            guard let studentHash = hash(studentURL), let teacherHash = hash(teacherURL) else { throw LibraryError.documentMissing }
            guard studentHash != teacherHash else { return .miss(.identicalCopies, "the Student and Teacher copies are the same bytes", key) }
            func copy(_ url: URL, _ hash: ContentHash, _ role: DocumentRole, _ title: String) throws -> LibraryCopy {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let publication = try Publication(subject: subject, classTag: naming.classTag, paperKey: key, role: role, title: title)
                let source = try SourcePath(classFolder: subject, relativePath: naming.displayName + "/" + role.rawValue + ".pdf")
                // Whole seconds, so the manifest round-trips through its ISO 8601 encoding unchanged.
                let modified = values.contentModificationDate.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
                let entry = try ManifestEntry(source: source, sha256: hash, size: Int64(values.fileSize ?? -1),
                                              modifiedAt: modified ?? Date(timeIntervalSince1970: .nan), publication: publication)
                return LibraryCopy(entry: entry, fileURL: url)
            }
            return .pair(try LibraryPair(paperKey: key, project: subject + "/" + project.lastPathComponent, rule: rule, buildID: build,
                                         student: copy(studentURL, studentHash, .student, titles.student),
                                         teacher: copy(teacherURL, teacherHash, .teacher, titles.teacher),
                                         withheldTerms: naming.withheldTerms))
        } catch {
            return .miss(.invalidRecord, "the selected pair cannot form a manifest entry", key)
        }
    }

    // MARK: File access (read-only)

    private mutating func matches(project: URL, build: String, student: String, teacher: String) -> Bool {
        let directory = project.appendingPathComponent("artifacts/\(build)", isDirectory: true)
        guard hasRealDirectoryChain(project: project, relativePath: "artifacts/\(build)") else { return false }
        guard let s = hash(directory.appendingPathComponent("student.pdf")), s.rawValue == student.lowercased(),
              let t = hash(directory.appendingPathComponent("teacher.pdf")), t.rawValue == teacher.lowercased() else { return false }
        return true
    }

    private mutating func hash(_ url: URL) -> ContentHash? {
        if let known = hashes[url.path] { return known }
        guard isFile(url), let digest = try? ContentHash.digest(fileAt: url) else { return nil }
        hashes[url.path] = digest
        return digest
    }

    private func json(_ url: URL) -> [String: Any]? {
        guard isFile(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 << 20,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func isFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func hasRealDirectoryChain(project: URL, relativePath: String) -> Bool {
        var directory = project
        for component in relativePath.split(separator: "/") {
            guard component != ".", component != ".." else { return false }
            directory.appendPathComponent(String(component), isDirectory: true)
            guard isDirectory(directory) else { return false }
        }
        return true
    }

    private func relativeDirectory(of file: URL, below project: URL) -> String {
        let root = project.standardizedFileURL.path + "/"
        let parent = file.deletingLastPathComponent().standardizedFileURL.path
        guard parent.hasPrefix(root) else { return ".." }
        return String(parent.dropFirst(root.count))
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)
    }

    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
#endif
