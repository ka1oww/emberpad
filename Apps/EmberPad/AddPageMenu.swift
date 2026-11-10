import SwiftUI
import PDFKit
import EmberSyncKit

// EP61: Add Page, laid out like GoodNotes' Add Page popover: Before / After / Last Page, a row of recent paper
// (one tap adds a page), and More Templates for size, orientation, colour and paper.

extension PaperTemplate {
    var kindTitle: String {
        switch kind {
        case .blank: "Blank"
        case .squared: "Squared"
        case .dotted: "Dotted"
        case .ruled: "Ruled"
        }
    }

    var sizeTitle: String { size == .letter ? "Letter" : size.rawValue.uppercased() }

    /// "A3 · Squared", with the orientation and colour only when they are not the usual portrait white.
    var title: String {
        var parts = [sizeTitle, kindTitle]
        if orientation == .landscape { parts.append("Landscape") }
        if color == .yellow { parts.append("Yellow") }
        return parts.joined(separator: " · ")
    }
}

extension PaperTemplate.Size {
    var title: String { self == .letter ? "Letter" : rawValue.uppercased() }
}

extension PageInsertPosition {
    var title: String {
        switch self {
        case .before: "Before"
        case .after: "After"
        case .last: "Last Page"
        }
    }
}

/// The remembered Add Page choice: where pages go and the paper used most recently, first. First run is the
/// captain's: A3 squared, after the page in view.
struct AddPageChoice: Codable, Equatable {
    static let defaultsKey = "addPage.v1"
    static let recentLimit = 4

    var position: PageInsertPosition = .after
    var recent: [PaperTemplate] = [.a3Squared]

    /// The paper the next page takes: the one used last.
    var current: PaperTemplate { recent.first ?? .a3Squared }

    mutating func used(_ template: PaperTemplate) {
        recent.removeAll { $0 == template }
        recent.insert(template, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
    }

    static func load(from defaults: UserDefaults = .standard) -> AddPageChoice {
        guard let data = defaults.data(forKey: defaultsKey),
              let choice = try? JSONDecoder().decode(AddPageChoice.self, from: data), !choice.recent.isEmpty else { return AddPageChoice() }
        return choice
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// A small picture of a paper, drawn from the same page the worksheet gets.
struct PaperPreview: View {
    let template: PaperTemplate
    var width: CGFloat = 64

    var body: some View {
        let size = template.pageSize
        let height = (width * size.height / size.width).rounded()
        Group {
            if let image = Self.image(template, width: width) {
                Image(uiImage: image).resizable()
            } else {
                Color.white
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Theme.line, lineWidth: Theme.hairlineWidth))
        .accessibilityHidden(true)
    }

    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor
    static func image(_ template: PaperTemplate, width: CGFloat) -> UIImage? {
        let key = "\(template.kind)-\(template.size)-\(template.orientation)-\(template.color)-\(width)"
        if let hit = cache[key] { return hit }
        guard let page = PaperTemplateRenderer.page(for: template) else { return nil }
        let size = template.pageSize
        // Twice the scale of the thumbnail, so the 5 mm grid stays visible.
        let image = page.thumbnail(of: CGSize(width: width * 3, height: width * 3 * size.height / size.width), for: .mediaBox)
        cache[key] = image
        return image
    }
}

/// The Add Page popover.
struct AddPagePopover: View {
    @Binding var choice: AddPageChoice
    /// Adds a page of this paper at the chosen position, then the popover closes.
    let add: (PaperTemplate) -> Void
    @State private var showsTemplates = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Position", selection: $choice.position) {
                    ForEach(PageInsertPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Add page position")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent").font(Theme.meta).foregroundStyle(Theme.text2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(choice.recent.enumerated()), id: \.element) { index, template in
                                Button { add(template) } label: {
                                    VStack(spacing: 6) {
                                        PaperPreview(template: template)
                                            .frame(height: 92, alignment: .bottom)
                                        Text(index == 0 ? "Current" : template.kindTitle)
                                            .font(Theme.pageMeta.weight(index == 0 ? .semibold : .regular))
                                            .foregroundStyle(Theme.text)
                                        Text(index == 0 ? template.title : template.sizeTitle)
                                            .font(Theme.pageMeta).foregroundStyle(Theme.text2)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 92)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Add \(template.title) page")
                            }
                        }
                    }
                }

                Divider()
                Button { showsTemplates = true } label: {
                    HStack {
                        Label("More Templates…", systemImage: "square.grid.2x2")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.text3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
            }
            .padding(16)
            .navigationTitle("Add Page")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsTemplates) {
                PaperTemplatePicker(initial: choice.current, apply: add)
            }
        }
        .frame(width: 380, height: 440)
        .tint(Theme.accent)
    }
}

/// More Templates: size, orientation, colour and paper, then Apply.
struct PaperTemplatePicker: View {
    let apply: (PaperTemplate) -> Void
    @State private var template: PaperTemplate

    init(initial: PaperTemplate, apply: @escaping (PaperTemplate) -> Void) {
        self.apply = apply
        _template = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Menu {
                        Picker("Size", selection: $template.size) {
                            ForEach(PaperTemplate.Size.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(template.sizeTitle, systemImage: "doc").font(Theme.meta)
                    }
                    .accessibilityLabel("Paper size, \(template.sizeTitle)")
                    Spacer()
                    Picker("Colour", selection: $template.color) {
                        Text("White").tag(PaperTemplate.Color.white)
                        Text("Yellow").tag(PaperTemplate.Color.yellow)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                Picker("Orientation", selection: $template.orientation) {
                    Text("Portrait").tag(PaperTemplate.Orientation.portrait)
                    Text("Landscape").tag(PaperTemplate.Orientation.landscape)
                }
                .pickerStyle(.segmented)
                Text("Essentials").font(Theme.meta).foregroundStyle(Theme.text2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 12) {
                    ForEach(PaperTemplate.Kind.allCases, id: \.self) { kind in
                        let option = PaperTemplate(kind: kind, size: template.size, orientation: template.orientation,
                                                   color: template.color)
                        Button { template.kind = kind } label: {
                            VStack(spacing: 6) {
                                PaperPreview(template: option, width: option.orientation == .portrait ? 58 : 76)
                                    .frame(height: 84, alignment: .bottom)
                                    .padding(3)
                                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(kind == template.kind ? Theme.accent : .clear, lineWidth: 2))
                                Text(option.kindTitle).font(Theme.pageMeta).foregroundStyle(Theme.text)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.kindTitle)
                        .accessibilityAddTraits(kind == template.kind ? .isSelected : [])
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply(template) }.fontWeight(.semibold)
            }
        }
    }
}
