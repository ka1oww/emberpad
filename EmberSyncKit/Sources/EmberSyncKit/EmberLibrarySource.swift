#if os(macOS)
import Foundation

/// Builds a library snapshot from the Google Drive EMBER folder. See `README.md`, "Library source: Drive EMBER
/// folder", for selection, pairing, privacy and carry-forward rules. It only reads.
public struct EmberLibrarySource: Sendable {
    /// Top-level folders with a fixed subject name. Any other top-level folder is a subject under its own name.
    public static let subjectNames = ["EMBER CHEMISTRY": "Chemistry", "EMBER MATH": "Math", "EMBER PHYSICS": "Physics",
                                      "EMBER BOOKLETS (MI + JC)": "Booklets"]
    /// Display order of the fixed subjects. Other subjects follow by name.
    public static let subjectOrder = ["Chemistry", "Math", "Physics", "Booklets"]
    /// Subject of a PDF that sits directly in the root folder.
    public static let rootSubject = "General"
    /// Shown for an entry with no class tag: a nil `classTag` means the copy belongs under every class.
    public static let allClassesLabel = "All classes"
    /// Folders that hold build output, not documents (case-insensitive). A folder whose name starts with one of
    /// `buildLeftoverFolderPrefixes` also counts. PDFs below them are counted as skipped and never read.
    public static let buildLeftoverFolders: Set<String> = ["redraws", "crops", "_build", "artifacts", "_assets", "_qa"]
    public static let buildLeftoverFolderPrefixes = ["_redraws"]
    /// Shared asset PDFs that every LaTeX source folder carries (case-insensitive), counted as skipped.
    public static let buildLeftoverFiles: Set<String> = ["ember-star.pdf"]

    /// The Drive EMBER folder, `~/Library/CloudStorage/GoogleDrive-*/My Drive/EMBER`, from the first Drive account
    /// folder (by name) that has one. Nil when Drive is not mounted or no account has the folder.
    public static func discoverDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let accounts = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        return accounts.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appendingPathComponent("My Drive", isDirectory: true).appendingPathComponent("EMBER", isDirectory: true) }
            .first { FileAccess.isDirectory($0) }
    }

    /// Orders subjects for display: the fixed subjects first, then any other subject by name.
    public static func displayOrder(_ subjects: some Sequence<String>) -> [String] {
        let present = Set(subjects)
        return subjectOrder + present.subtracting(subjectOrder).sorted()
    }

    public let root: URL
    public let aliases: ClassAliasTable
    private let metadataReader: @Sendable (URL) throws -> ChildMetadata

    /// `root` is used as given; pass `discoverDriveRoot()` for the Drive EMBER folder. Tests pass synthetic roots.
    public init(root: URL, aliases: ClassAliasTable = .empty) {
        self.root = root
        self.aliases = aliases
        self.metadataReader = { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            return ChildMetadata(isDirectory: values.isDirectory, isRegularFile: values.isRegularFile,
                                 isSymbolicLink: values.isSymbolicLink)
        }
    }

    init(root: URL, aliases: ClassAliasTable = .empty,
         metadataReader: @escaping @Sendable (URL) throws -> ChildMetadata) {
        self.root = root
        self.aliases = aliases
        self.metadataReader = metadataReader
    }

    /// Walks the root and returns a version-2 manifest plus the miss list. `previous` is the manifest last
    /// delivered: any of its copies that is not found again, or not read this time, is carried forward unchanged.
    /// Throws when the root is not a real directory or cannot be listed.
    public func read(previous: Manifest? = nil, generatedAt: Date = Date()) throws -> LibrarySnapshot {
        guard FileAccess.isDirectory(root) else { throw CocoaError(.fileReadNoSuchFile) }
        var walker = Walker(root: root, aliases: aliases, metadataReader: metadataReader)
        try walker.walk()
        var misses = walker.misses
        let withheld = aliases.withheldTerms + walker.withheldTerms

        var documents = Gate.unique(walker.documents, misses: &misses)
        documents = documents.filter { document in
            guard Gate.passesPrivacy(document.entry, terms: withheld) else {
                misses.append(LibraryMiss(path: document.localPath, reason: .privacyWithheld,
                                          detail: "a manifest string failed the final privacy check", paperKey: document.entry.paperKey))
                return false
            }
            return true
        }
        documents = Gate.crossRole(documents, misses: &misses)

        var files = documents.map(\.entry)
        var retained: [LibraryRetained] = []
        if let previous {
            let unreadKeys = Set(misses.filter { $0.reason == .unreadable }.compactMap(\.paperKey))
            let heldKeys = Set(misses.filter { $0.reason != .unreadable }.compactMap(\.paperKey))
            var copies = Set(files.compactMap(Gate.copyKey))
            var occupied = Set(files.map(\.source))
            for entry in previous.files {
                guard let key = entry.paperKey, let copy = Gate.copyKey(entry), !copies.contains(copy), !occupied.contains(entry.source)
                else { continue }
                guard Gate.passesPrivacy(entry, terms: withheld) else {
                    misses.append(LibraryMiss(path: key.rawValue, reason: .privacyWithheld,
                                              detail: "a previous entry failed the final privacy check", paperKey: key))
                    continue
                }
                let underUnreadFolder = walker.unreadSourcePrefixes.contains { entry.source.key.hasPrefix($0 + "/") }
                let reason: LibraryRetained.Reason = unreadKeys.contains(key) || underUnreadFolder ? .sourceUnreadable
                    : heldKeys.contains(key) ? .heldBack : .sourceVanished
                retained.append(LibraryRetained(entry: entry, reason: reason))
                copies.insert(copy)
                occupied.insert(entry.source)
                files.append(entry)
            }
            // A carried Student copy must not match any Teacher copy, current or carried.
            let teacherHashes = Set(files.filter { $0.role == .teacher }.map(\.sha256))
            let blocked = retained.filter { $0.entry.role == .student && teacherHashes.contains($0.entry.sha256) }
            for item in blocked {
                misses.append(LibraryMiss(path: item.entry.paperKey?.rawValue ?? item.entry.source.key, reason: .studentMatchesTeacher,
                                          detail: "a previous Student copy has the same bytes as a Teacher copy",
                                          paperKey: item.entry.paperKey))
            }
            // Carried sources are never a current document's source, so removing them by source leaves current copies.
            let blockedSources = Set(blocked.map(\.entry.source))
            retained.removeAll { blockedSources.contains($0.entry.source) }
            files.removeAll { $0.role == .student && blockedSources.contains($0.source) }
        }

        let manifest = try Manifest(version: 2, generatedAt: generatedAt, files: files)
        return LibrarySnapshot(manifest: manifest, documents: documents,
                               misses: misses.sorted { ($0.path, $0.reason.rawValue) < ($1.path, $1.reason.rawValue) },
                               retained: retained, skippedLeftoverPDFs: walker.skippedLeftoverPDFs,
                               skippedOtherFiles: walker.skippedOtherFiles)
    }
}

struct ChildMetadata: Sendable {
    let isDirectory: Bool?
    let isRegularFile: Bool?
    let isSymbolicLink: Bool?
}

/// One delivered copy: the manifest entry the iPad sees, and where it was read from (Mac only).
public struct LibraryDocument: Equatable, Sendable {
    public let entry: ManifestEntry
    public let fileURL: URL
    /// Local only: the path below the root, as found. It can carry a person's name, so it never goes in the manifest.
    public let localPath: String
    public init(entry: ManifestEntry, fileURL: URL, localPath: String) {
        self.entry = entry
        self.fileURL = fileURL
        self.localPath = localPath
    }
}

/// A PDF or folder that was found but not delivered this time. `path` is local (below the root) and stays on the Mac.
public struct LibraryMiss: Equatable, Sendable {
    public enum Reason: String, Sendable, CaseIterable {
        /// The file or folder could not be read, for example Drive is offline or the file is not downloaded yet.
        case unreadable
        case duplicatePaperKey = "duplicate-paper-key"
        case privacyWithheld = "privacy-withheld"
        case identicalCopies = "identical-copies"
        case studentMatchesTeacher = "student-matches-a-teacher-copy"
        /// The name cannot form a safe manifest path or label.
        case invalidName = "invalid-name"
    }
    public let path: String
    public let reason: Reason
    public let detail: String
    /// The paper key the copy would have had, when one could be formed. Local only.
    public let paperKey: PaperKey?

    public init(path: String, reason: Reason, detail: String, paperKey: PaperKey? = nil) {
        self.path = path
        self.reason = reason
        self.detail = detail
        self.paperKey = paperKey
    }
}

/// A copy kept unchanged from the previous manifest because it was not delivered again.
public struct LibraryRetained: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case sourceVanished = "source-vanished"
        case sourceUnreadable = "source-unreadable"
        /// Found again, but this run's copy is a miss (privacy, duplicate or cross-role).
        case heldBack = "held-back"
    }
    public let entry: ManifestEntry
    public let reason: Reason
}

public struct LibrarySnapshot: Equatable, Sendable {
    /// Version 2: documents found this run first, then retained entries.
    public let manifest: Manifest
    public let documents: [LibraryDocument]
    public let misses: [LibraryMiss]
    public let retained: [LibraryRetained]
    /// PDFs below build-leftover folders, plus shared asset PDFs. Counted, never read or listed.
    public let skippedLeftoverPDFs: Int
    /// Non-PDF files (tex, png, json and other build output). Hidden entries are not counted.
    public let skippedOtherFiles: Int

    public init(manifest: Manifest, documents: [LibraryDocument], misses: [LibraryMiss], retained: [LibraryRetained],
                skippedLeftoverPDFs: Int = 0, skippedOtherFiles: Int = 0) {
        self.manifest = manifest
        self.documents = documents
        self.misses = misses
        self.retained = retained
        self.skippedLeftoverPDFs = skippedLeftoverPDFs
        self.skippedOtherFiles = skippedOtherFiles
    }

    private var rolesByKey: [PaperKey: Set<DocumentRole>] {
        var roles: [PaperKey: Set<DocumentRole>] = [:]
        for document in documents { if let key = document.entry.paperKey { roles[key, default: []].insert(document.entry.role) } }
        return roles
    }
    /// Paper keys found this run with both a Student and a Teacher copy.
    public var pairCount: Int { rolesByKey.values.filter { $0.count == 2 }.count }
    /// Copies found this run with no partner of the other role.
    public var singleCopyCount: Int { rolesByKey.values.filter { $0.count == 1 }.count }
    public var archivedCount: Int { documents.filter(\.entry.isArchived).count }
    public var documentBytes: Int64 { documents.reduce(0) { $0 + $1.entry.size } }
    /// Documents found this run, per subject.
    public var documentCounts: [String: Int] {
        Dictionary(documents.map { ($0.entry.subject, 1) }, uniquingKeysWith: +)
    }
}

// MARK: - Teacher and Student name markers

/// Role markers at the end of a PDF name. A Teacher-marked PDF pairs with the same-directory PDF whose name is the
/// same once the marker is removed (case and spacing ignored); a Student marker is removed the same way.
enum RoleMarker {
    private static let teacherWords = #"teachers?(?:'s)?(?:\s+(?:copy|version|edition))?|solutions?|answers?|answer\s+key|mark\s+scheme"#
    private static let studentWords = #"students?(?:'s)?(?:\s+(?:copy|version|edition))?"#

    private static func patterns(_ words: String) -> [NSRegularExpression] {
        [
            #"^(.*?)\s*[\(\[]\s*(?:\#(words))\s*[\)\]]\s*$"#,  // "Name (Teacher)", "Name [Teacher Copy]"
            #"^(.*?)\s*[-–—_]\s*(?:\#(words))\s*$"#,           // "Name - Teacher", "Name — TEACHERS", "Name - Solutions"
            #"^(.*\S)\s+(?:\#(words))\s*$"#,                   // "Name Teacher"
            #"^()(?:\#(words))$"#                              // "teacher"
        ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }
    // Also "Name (Teacher, other notes)": a bracketed group at the end that names the Teacher copy.
    private static let teacher = patterns(teacherWords) + [
        try! NSRegularExpression(pattern: #"^(.*?)\s*[\(\[][^\(\)\[\]]*\bteachers?\b[^\(\)\[\]]*[\)\]]\s*$"#, options: [.caseInsensitive])
    ]
    private static let student = patterns(studentWords)

    /// The role a name's marker says and the name without it. An unmarked name is a Student copy named as is.
    static func parse(_ stem: String) -> (role: DocumentRole, base: String, marked: Bool) {
        if let base = strip(stem, teacher) { return (.teacher, base, true) }
        if let base = strip(stem, student) { return (.student, base, true) }
        return (.student, stem, false)
    }

    private static func strip(_ stem: String, _ expressions: [NSRegularExpression]) -> String? {
        let range = NSRange(stem.startIndex..., in: stem)
        for expression in expressions {
            guard let match = expression.firstMatch(in: stem, range: range), let base = Range(match.range(at: 1), in: stem) else { continue }
            return stem[base].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Comparison form: case and runs of spaces ignored.
    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// Maps a folder- or file-name prefix to a class tag, for prefixes such as a personal name followed by "Sec 3".
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

// MARK: - Class from a folder- or file-name prefix

struct ClassResolution: Equatable {
    /// Nil is the "All classes" bucket.
    let classTag: String?
    /// The name with any personal prefix replaced by its class or removed.
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

// MARK: - Gates applied to every copy before it reaches the manifest

enum Gate {
    struct CopyKey: Hashable {
        let paperKey: PaperKey
        let role: DocumentRole
    }

    static func copyKey(_ entry: ManifestEntry) -> CopyKey? { entry.paperKey.map { CopyKey(paperKey: $0, role: entry.role) } }

    /// Copies that would share a paper key and role, or a manifest path, are all held back rather than guessed between.
    static func unique(_ documents: [LibraryDocument], misses: inout [LibraryMiss]) -> [LibraryDocument] {
        let keyCounts = Dictionary(documents.compactMap { copyKey($0.entry) }.map { ($0, 1) }, uniquingKeysWith: +)
        let pathCounts = Dictionary(documents.map { ($0.entry.source, 1) }, uniquingKeysWith: +)
        return documents.filter { document in
            let unique = copyKey(document.entry).map { keyCounts[$0] == 1 } == true && pathCounts[document.entry.source] == 1
            if !unique {
                misses.append(LibraryMiss(path: document.localPath, reason: .duplicatePaperKey,
                                          detail: "another PDF would show under the same paper key and role, or the same path",
                                          paperKey: document.entry.paperKey))
            }
            return unique
        }
    }

    /// A Student copy whose bytes equal any Teacher copy would show answers to students, so it is held back. The
    /// Teacher copy is still delivered.
    static func crossRole(_ documents: [LibraryDocument], misses: inout [LibraryMiss]) -> [LibraryDocument] {
        let teachers = documents.filter { $0.entry.role == .teacher }
        let teacherHashes = Set(teachers.map(\.entry.sha256))
        return documents.filter { document in
            guard document.entry.role == .student, teacherHashes.contains(document.entry.sha256) else { return true }
            let ownTeacher = teachers.contains { $0.entry.paperKey == document.entry.paperKey && $0.entry.sha256 == document.entry.sha256 }
            misses.append(LibraryMiss(path: document.localPath, reason: ownTeacher ? .identicalCopies : .studentMatchesTeacher,
                                      detail: ownTeacher ? "the Student and Teacher copies are the same bytes"
                                          : "a Student copy has the same bytes as a Teacher copy",
                                      paperKey: document.entry.paperKey))
            return false
        }
    }

    static func passesPrivacy(_ entry: ManifestEntry, terms: [String]) -> Bool {
        let strings = [entry.source.key, entry.source.relativePath, entry.title, entry.subject] +
            (entry.classTag.map { [$0] } ?? []) + (entry.paperKey.map { [$0.rawValue] } ?? [])
        let invalidClassTag = entry.classTag.map { !ClassResolver.isClassTag($0) } ?? false
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
}

// MARK: - Walking the root (read-only)

private struct Walker {
    /// Where a folder sits: its subject, the raw folder names below the subject folder, and its local path.
    struct Context {
        let subject: String
        let folders: [String]
        let localPath: String
        let archived: Bool

        func entering(_ name: String) -> Context {
            Context(subject: subject, folders: folders + [name], localPath: localPath.isEmpty ? name : localPath + "/" + name,
                    archived: archived || name.hasPrefix("_"))
        }
    }

    struct Child {
        let url: URL
        let name: String
        let isDirectory: Bool?
    }

    let root: URL
    let aliases: ClassAliasTable
    let metadataReader: @Sendable (URL) throws -> ChildMetadata
    let fileManager = FileManager.default
    var documents: [LibraryDocument] = []
    var misses: [LibraryMiss] = []
    var withheldTerms: [String] = []
    /// Manifest-path prefixes (`<subject>/<folders>`) of folders that could not be listed this run.
    var unreadSourcePrefixes: [String] = []
    var skippedLeftoverPDFs = 0
    var skippedOtherFiles = 0

    init(root: URL, aliases: ClassAliasTable, metadataReader: @escaping @Sendable (URL) throws -> ChildMetadata) {
        self.root = root
        self.aliases = aliases
        self.metadataReader = metadataReader
    }

    mutating func walk() throws {
        let children = try list(root)
        let rootContext = Context(subject: EmberLibrarySource.rootSubject, folders: [], localPath: "", archived: false)
        files(children.filter { $0.isDirectory == false || ($0.isDirectory == nil && Self.isPDF($0.name)) }, in: rootContext)
        for child in children where child.isDirectory == true {
            if Self.isLeftoverFolder(child.name) { countLeftovers(in: child.url); continue }
            let archived = child.name.hasPrefix("_")
            let ownName = archived ? String(child.name.drop(while: { $0 == "_" })) : child.name
            let subject = EmberLibrarySource.subjectNames[child.name] ?? (ownName.isEmpty ? child.name : ownName)
            folder(child.url, Context(subject: subject, folders: [], localPath: child.name, archived: archived))
        }
        for child in children where child.isDirectory == nil && !Self.isPDF(child.name) {
            let archived = child.name.hasPrefix("_")
            let ownName = archived ? String(child.name.drop(while: { $0 == "_" })) : child.name
            let subject = EmberLibrarySource.subjectNames[child.name] ?? (ownName.isEmpty ? child.name : ownName)
            markUnreadableFolder(Context(subject: subject, folders: [], localPath: child.name, archived: archived))
        }
    }

    private mutating func folder(_ url: URL, _ context: Context) {
        let children: [Child]
        do { children = try list(url) } catch {
            misses.append(LibraryMiss(path: context.localPath, reason: .unreadable,
                                      detail: "the folder could not be listed (Drive offline or not available)"))
            let rewritten = context.folders.map { ClassResolver.resolve($0, aliases: aliases).displayName }
            unreadSourcePrefixes.append(([context.subject] + rewritten).joined(separator: "/"))
            return
        }
        files(children.filter { $0.isDirectory == false || ($0.isDirectory == nil && Self.isPDF($0.name)) }, in: context)
        for child in children where child.isDirectory == true {
            if Self.isLeftoverFolder(child.name) { countLeftovers(in: child.url); continue }
            folder(child.url, context.entering(child.name))
        }
        for child in children where child.isDirectory == nil && !Self.isPDF(child.name) {
            markUnreadableFolder(context.entering(child.name))
        }
    }

    /// Pairs the PDFs of one folder by name, then reads each one.
    private mutating func files(_ files: [Child], in context: Context) {
        var pdfs: [(child: Child, stem: String, ext: String, role: DocumentRole, base: String)] = []
        for file in files {
            let lower = file.name.lowercased()
            guard lower.hasSuffix(".pdf"), file.name.count > 4 else { skippedOtherFiles += 1; continue }
            if EmberLibrarySource.buildLeftoverFiles.contains(lower) { skippedLeftoverPDFs += 1; continue }
            let stem = String(file.name.dropLast(4)), ext = String(file.name.suffix(4))
            let marker = RoleMarker.parse(stem)
            pdfs.append((file, stem, ext, marker.role, marker.base))
        }
        let groups = Dictionary(grouping: pdfs, by: { RoleMarker.normalized($0.base) })
        for name in groups.keys.sorted() {
            guard let copies = groups[name]?.sorted(by: { $0.child.name < $1.child.name }) else { continue }
            // Both copies of a pair share the paper key named after the Student copy's unmarked name.
            let base = (copies.first { $0.role == .student } ?? copies[0]).base
            for copy in copies {
                read(copy.child, stem: copy.stem, ext: copy.ext, role: copy.role, base: base, context: context)
            }
        }
    }

    private mutating func read(_ file: Child, stem: String, ext: String, role: DocumentRole, base: String, context: Context) {
        let localPath = context.localPath.isEmpty ? file.name : context.localPath + "/" + file.name
        func miss(_ reason: LibraryMiss.Reason, _ detail: String, _ key: PaperKey? = nil) {
            misses.append(LibraryMiss(path: localPath, reason: reason, detail: detail, paperKey: key))
        }
        let folderNames = context.folders.map { ClassResolver.resolve($0, aliases: aliases) }
        let stemName = ClassResolver.resolve(stem, aliases: aliases)
        let baseName = base.isEmpty ? nil : ClassResolver.resolve(base, aliases: aliases)
        withheldTerms += folderNames.flatMap(\.withheldTerms) + stemName.withheldTerms + (baseName?.withheldTerms ?? [])

        let folders = folderNames.map { $0.displayName.trimmingCharacters(in: .whitespaces) }
        let fileStem = stemName.displayName.trimmingCharacters(in: .whitespaces)
        guard !folders.contains(where: \.isEmpty), !fileStem.isEmpty else {
            return miss(.invalidName, "a name is empty once personal-name words are removed")
        }
        let keyBase = baseName?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        let key = try? PaperKey(rawValue: ([context.subject] + folders + [keyBase]).joined(separator: "/"))
        let titleFolders = zip(context.folders, folders).filter { !$0.0.hasPrefix("_") }.map(\.1)
        let classTag = folderNames.lazy.compactMap(\.classTag).first ?? stemName.classTag
        guard let key, let source = try? SourcePath(classFolder: context.subject, relativePath: (folders + [fileStem + ext]).joined(separator: "/")),
              let publication = try? Publication(subject: context.subject, classTag: classTag, paperKey: key, role: role,
                                                 title: (titleFolders + [fileStem]).joined(separator: " / "), archived: context.archived)
        else { return miss(.invalidName, "the name cannot form a safe manifest path or label") }

        if file.isDirectory == nil {
            return miss(.unreadable, "the entry's metadata could not be read", key)
        }

        let values: URLResourceValues, hash: ContentHash
        do {
            values = try file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            hash = try ContentHash.digest(fileAt: file.url)
        } catch {
            return miss(.unreadable, "the file could not be read (Drive offline or not downloaded yet)", key)
        }
        // Whole seconds, so the manifest round-trips through its ISO 8601 encoding unchanged.
        let modified = values.contentModificationDate.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        guard let size = values.fileSize, let modified,
              let entry = try? ManifestEntry(source: source, sha256: hash, size: Int64(size), modifiedAt: modified, publication: publication)
        else { return miss(.unreadable, "the file's size or modification date could not be read", key) }
        documents.append(LibraryDocument(entry: entry, fileURL: file.url, localPath: localPath))
    }

    private static func isLeftoverFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return EmberLibrarySource.buildLeftoverFolders.contains(lower) ||
            EmberLibrarySource.buildLeftoverFolderPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func isPDF(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".pdf") && name.count > 4
    }

    private mutating func markUnreadableFolder(_ context: Context) {
        misses.append(LibraryMiss(path: context.localPath, reason: .unreadable,
                                  detail: "the folder's metadata could not be read"))
        let rewritten = context.folders.map { ClassResolver.resolve($0, aliases: aliases).displayName }
        unreadSourcePrefixes.append(([context.subject] + rewritten).joined(separator: "/"))
    }

    /// Counts PDFs below a build-leftover folder from the listing alone; nothing is opened.
    private mutating func countLeftovers(in folder: URL) {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                  options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" && FileAccess.isFile(url) {
            skippedLeftoverPDFs += 1
        }
    }

    /// Non-hidden children, sorted by name. Symlinks are not followed; metadata failures remain as unreadable children.
    private func list(_ folder: URL) throws -> [Child] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        return try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> Child? in
                guard let values = try? metadataReader(url) else {
                    return Child(url: url, name: url.lastPathComponent, isDirectory: nil)
                }
                guard values.isSymbolicLink != true else { return nil }
                if values.isDirectory == true {
                    return Child(url: url, name: url.lastPathComponent, isDirectory: true)
                }
                if values.isRegularFile == true {
                    return Child(url: url, name: url.lastPathComponent, isDirectory: false)
                }
                return nil
            }
            .sorted { $0.name < $1.name }
    }
}

enum FileAccess {
    static func isFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
#endif
