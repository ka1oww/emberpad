import AppKit
import XCTest
@testable import EmberPadCompanion

/// EP178: the iPad app's user-facing name is Ember Slate, and the Mac app's is Ember Companion. No text the Companion
/// (or the iPad app) shows says "EmberPad", which is only the project's name: its targets, bundle ids, folders on disk,
/// settings keys and code keep it.
@MainActor
final class CompanionCopyTests: XCTestCase {
    func testTheCompanionNamesTheIPadAppEmberSlate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionCopyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let window = PresentWindowController()
        let model = CompanionPresentModel(window: window,
                                          backdrop: PresentBackdropStore(url: folder.appendingPathComponent("backdrop.jpg")))
        XCTAssertEqual(model.status, .off)
        XCTAssertEqual(model.statusText, "Not presenting. Turn on Present on Mac in Ember Slate on the iPad.")
        XCTAssertEqual(PresentWindowController.windowTitle, "Ember Slate Presentation")
    }

    /// The Companion's Info.plist, as built: its name and the permission prompts macOS shows.
    func testTheCompanionsBundleStringsDoNotSayEmberPad() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Ember Companion")
        for (key, value) in info {
            guard let text = value as? String else { continue }
            XCTAssertFalse(text.contains("EmberPad"), "\(key) says \"\(text)\"")
        }
    }

    /// Every string literal in the Companion, the iPad app and EmberSyncKit that contains "EmberPad" is one the user
    /// never reads. Anything else (a label, a message, a title, an accessibility label) fails here by file and line.
    func testNoUserFacingStringInTheAppsSaysEmberPad() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folders = ["Apps/Companion", "Apps/EmberPad", "EmberSyncKit/Sources"].map { root.appendingPathComponent($0) }
        var scanned = 0
        var offending: [String] = []
        for folder in folders {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil),
                                      "the sources are at \(folder.path)")
            for case let file as URL in files where ["swift", "plist"].contains(file.pathExtension) {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line, literal) in Self.literals(in: text, plist: file.pathExtension == "plist")
                where literal.contains("EmberPad") && !Self.isNeverShown(literal, line: line) {
                    offending.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(number): \(literal)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found the app sources")
        XCTAssertEqual(offending, [], "user-facing text says EmberPad:\n" + offending.joined(separator: "\n"))
    }

    /// Strings with "EmberPad" that no one reads in the app, and why each stays.
    private static func isNeverShown(_ literal: String, line: String) -> Bool {
        // Settings keys and dispatch queue labels ("EmberPadCompanion.emberFolderPath", "EmberPad.sync.lastSynced").
        if literal.range(of: #"^EmberPad(Companion)?\.[A-Za-z]"#, options: .regularExpression) != nil { return true }
        // UI-test launch arguments.
        if literal.hasPrefix("-EmberPad") { return true }
        // Folders on disk. Renaming them would leave the teacher's backups, imports and backdrop behind.
        if literal.contains("Application Support/EmberPad") { return true }
        // Log lines, read only in Console.
        if line.contains("NSLog(") || line.contains("Logger(") { return true }
        // The pairing key's derivation salt. Changing it would break every pairing.
        if literal == "EmberPad pairing v1" { return true }
        // The Keychain item's label, set once when a pairing is saved and kept on items saved before.
        if literal == "EmberPad pairing" { return true }
        // Brand sources and build paths.
        if literal == "EmberPad" && line.contains("Brand.Sources") { return true }
        return false
    }

    /// The string literals on each line that is not a comment, with its line number and the whole line.
    private static func literals(in text: String, plist: Bool) -> [(Int, String, String)] {
        var found: [(Int, String, String)] = []
        var multiline: String?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let number = index + 1
            if plist {
                // A plist's values: <string>…</string>.
                let pattern = #"<string>([^<]*)</string>"#
                let regex = try! NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    found.append((number, line, String(line[Range(match.range(at: 1), in: line)!])))
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = multiline {
                if trimmed.hasPrefix("\"\"\"") {
                    found.append((number, line, open))
                    multiline = nil
                } else {
                    open += line + "\n"
                    multiline = open
                }
                continue
            }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            if trimmed.hasSuffix("\"\"\"") && trimmed.components(separatedBy: "\"\"\"").count == 2 {
                multiline = ""
                continue
            }
            // Everything before a trailing comment.
            let code = Self.stripComment(line)
            let regex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                found.append((number, line, String(code[Range(match.range(at: 1), in: code)!])))
            }
        }
        return found
    }

    /// `line` without a `//` comment that starts outside a string.
    private static func stripComment(_ line: String) -> String {
        var inString = false, escaped = false
        var previous: Character?
        var result = ""
        for character in line {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "/" && previous == "/" {
                result.removeLast()
                return result
            }
            result.append(character)
            previous = character
        }
        return result
    }
}
