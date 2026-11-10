import SwiftUI
import PDFKit

/// One match of an in-document search (EP63): where it is and a short piece of its line.
struct WorksheetSearchHit: Identifiable {
    let id: Int
    /// Zero-based page of the worksheet.
    let page: Int
    let snippet: WorksheetSearchSnippet
    let selection: PDFSelection
}

/// The text around a match, split so the match can be shown in bold.
struct WorksheetSearchSnippet: Equatable {
    var before: String
    var match: String
    var after: String

    var text: String { before + match + after }
}

/// Searches the worksheet's own PDF text (EP63), as GoodNotes' Search does. Pages added in Ember Slate are blank
/// paper with no text, so they never match. Handwriting is not searched.
enum WorksheetSearch {
    /// Case- and accent-insensitive, as library title search is.
    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    /// How much of the line a snippet keeps either side of the match, in characters.
    static let snippetLead = 36
    static let snippetTail = 48

    /// Every match of `query` in `document`, in page order. A blank query finds nothing.
    @MainActor
    static func hits(for query: String, in document: PDFDocument) -> [WorksheetSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let found = document.findString(needle, withOptions: options)
        return found.enumerated().compactMap { offset, selection in
            guard let page = selection.pages.first else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            return WorksheetSearchHit(id: offset, page: index, snippet: snippet(for: selection), selection: selection)
        }
    }

    /// The match with the rest of its line around it.
    static func snippet(for selection: PDFSelection) -> WorksheetSearchSnippet {
        let match = selection.string ?? ""
        guard let line = selection.copy() as? PDFSelection else { return snippet(line: match, match: match) }
        line.extendForLineBoundaries()
        return snippet(line: line.string ?? match, match: match)
    }

    /// Cuts `line` down to the match with up to `snippetLead` characters before it and `snippetTail` after, on word
    /// boundaries where it can, marking a cut with "…". Runs of white space become one space.
    static func snippet(line: String, match: String) -> WorksheetSearchSnippet {
        let flat = collapse(line)
        let needle = collapse(match)
        guard !needle.isEmpty, let range = flat.range(of: needle, options: options) else {
            return WorksheetSearchSnippet(before: "", match: needle.isEmpty ? flat : needle, after: "")
        }
        var before = String(flat[..<range.lowerBound])
        var after = String(flat[range.upperBound...])
        if before.count > snippetLead {
            before = "…" + trimmedToWord(String(before.suffix(snippetLead)), fromStart: true)
        }
        if after.count > snippetTail {
            after = trimmedToWord(String(after.prefix(snippetTail)), fromStart: false) + "…"
        }
        return WorksheetSearchSnippet(before: before, match: String(flat[range]), after: after)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Drops a partial word at the cut end, unless that would leave nothing.
    private static func trimmedToWord(_ text: String, fromStart: Bool) -> String {
        if fromStart {
            guard let space = text.firstIndex(of: " "), text.index(after: space) < text.endIndex else { return text }
            return String(text[text.index(after: space)...])
        }
        guard let space = text.lastIndex(of: " "), space > text.startIndex else { return text }
        return String(text[..<space])
    }
}

/// The header's Search popover state (EP63): the query, its matches and the one chosen. While the popover is open
/// every match is highlighted on its page and the chosen one more strongly; closing it clears the highlights.
@MainActor
final class WorksheetSearchModel: ObservableObject {
    @Published var isOpen = false {
        didSet { if isOpen != oldValue { publish() } }
    }
    @Published private(set) var query = ""
    @Published private(set) var hits: [WorksheetSearchHit] = []
    /// The chosen match, an index into `hits`.
    @Published private(set) var current: Int?
    /// Highlights `matches` on the pages, the `current` one strongly; the editor sets it to its renderer.
    var highlight: ((_ matches: [PDFSelection], _ current: Int?) -> Void)?
    /// Scrolls the worksheet to a match; the editor sets it to its renderer.
    var reveal: ((PDFSelection) -> Void)?
    private var document: PDFDocument?
    private var pending: Task<Void, Never>?
    private let delay: Duration

    init(delay: Duration = .milliseconds(200)) { self.delay = delay }

    /// "3 of 12", "12 results" or "No results"; nil before anything is typed.
    var countText: String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if hits.isEmpty { return "No results" }
        if let current { return "\(current + 1) of \(hits.count)" }
        return hits.count == 1 ? "1 result" : "\(hits.count) results"
    }

    /// The worksheet opened, or reopened on new pages after a page edit: the search runs again on its pages.
    func attach(_ document: PDFDocument) {
        self.document = document
        run()
    }

    /// Typing: the search runs once the typing pauses.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        pending?.cancel()
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    /// Searches now, as Return does before choosing the first match.
    func run() {
        pending?.cancel()
        pending = nil
        hits = document.map { WorksheetSearch.hits(for: query, in: $0) } ?? []
        current = nil
        publish()
    }

    /// A tapped match: it becomes the chosen one and the worksheet scrolls to it.
    func select(_ index: Int) {
        guard hits.indices.contains(index) else { return }
        current = index
        publish()
        reveal?(hits[index].selection)
    }

    /// The down chevron and Return: the next match, wrapping round, or the first.
    func next() {
        if pending != nil { run() }
        guard !hits.isEmpty else { return }
        select(current.map { ($0 + 1) % hits.count } ?? 0)
    }

    /// The up chevron: the previous match, wrapping round, or the last.
    func previous() {
        if pending != nil { run() }
        guard !hits.isEmpty else { return }
        select(current.map { ($0 - 1 + hits.count) % hits.count } ?? hits.count - 1)
    }

    func close() { isOpen = false }

    private func publish() {
        if isOpen { highlight?(hits.map(\.selection), current) } else { highlight?([], nil) }
    }
}

/// GoodNotes' Search popover (EP63): a field with the keyboard up, the match count with previous and next, and the
/// matches, each with its page number and the text around it. Tapping one shows it on its page.
struct WorksheetSearchPopover: View {
    @ObservedObject var search: WorksheetSearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Search in Worksheet", text: Binding(get: { search.query }, set: { search.setQuery($0) }))
                        .focused($fieldFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit {
                            search.next()
                            fieldFocused = true
                        }
                    if !search.query.isEmpty {
                        Button { search.setQuery(""); search.run() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if let count = search.countText {
                HStack(spacing: 4) {
                    Text(count)
                        .font(Theme.meta)
                        .foregroundStyle(Theme.text2)
                        .accessibilityIdentifier("search-count")
                    Spacer()
                    Button { search.previous() } label: { Image(systemName: "chevron.up").frame(width: 36, height: 30) }
                        .accessibilityLabel("Previous result")
                    Button { search.next() } label: { Image(systemName: "chevron.down").frame(width: 36, height: 30) }
                        .accessibilityLabel("Next result")
                }
                .disabled(search.hits.isEmpty)
                .padding(.horizontal, 16).padding(.bottom, 6)
                Divider()
            }
            if search.hits.isEmpty {
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    List(search.hits) { hit in
                        Button { search.select(hit.id) } label: { WorksheetSearchRow(hit: hit, isCurrent: hit.id == search.current) }
                            .listRowBackground(hit.id == search.current ? Theme.accentSoft : Theme.bg)
                            .id(hit.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: search.current) { _, current in
                        if let current { withAnimation { proxy.scrollTo(current, anchor: .center) } }
                    }
                }
            }
        }
        .frame(width: 360, height: search.countText == nil ? 72 : 420)
        .background(Theme.bg)
        .tint(Theme.accent)
        .onAppear {
            // Let the popover finish presenting so the keyboard comes up with it.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }
}

private struct WorksheetSearchRow: View {
    let hit: WorksheetSearchHit
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Page \(hit.page + 1)")
                .font(Theme.meta.weight(.semibold))
                .foregroundStyle(isCurrent ? Theme.accent : Theme.text2)
                .frame(width: 58, alignment: .leading)
            (Text(hit.snippet.before) + Text(hit.snippet.match).bold().foregroundStyle(Theme.text) + Text(hit.snippet.after))
                .font(.subheadline)
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(hit.page + 1): \(hit.snippet.text)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
