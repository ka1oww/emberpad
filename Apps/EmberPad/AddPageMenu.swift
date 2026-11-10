import SwiftUI
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

/// A small picture of a paper. The worksheet's real 5 mm grid shrinks below a pixel at this size, so the preview
/// draws the same pattern at a pitch that stays visible, in the paper's colour and proportions.
struct PaperPreview: View {
    let template: PaperTemplate
    var width: CGFloat = 64

    var body: some View {
        let size = template.pageSize
        let height = (width * size.height / size.width).rounded()
        Canvas { context, canvas in
            let paper = template.color == .yellow ? PaperTemplateRenderer.yellowPaper : UIColor.white
            context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(Color(paper)))
            let pitch = canvas.width / 10
            let line = Color(red: 0xC4 / 255, green: 0xC4 / 255, blue: 0xC4 / 255)
            switch template.kind {
            case .blank:
                break
            case .squared:
                var path = Path()
                for x in PaperTemplateRenderer.lines(across: canvas.width, pitch: pitch) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: canvas.height))
                }
                for y in PaperTemplateRenderer.lines(across: canvas.height, pitch: pitch) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: canvas.width, y: y))
                }
                context.stroke(path, with: .color(line), lineWidth: 0.5)
            case .dotted:
                for x in PaperTemplateRenderer.lines(across: canvas.width, pitch: pitch) {
                    for y in PaperTemplateRenderer.lines(across: canvas.height, pitch: pitch) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                                     with: .color(Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xA6 / 255)))
                    }
                }
            case .ruled:
                var path = Path()
                var y = pitch * 2
                while y < canvas.height - pitch / 2 {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: canvas.width, y: y))
                    y += pitch * 1.4
                }
                context.stroke(path, with: .color(line), lineWidth: 0.5)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Theme.line, lineWidth: Theme.hairlineWidth))
        .accessibilityHidden(true)
    }
}

/// The Add Page popover.
struct AddPagePopover: View {
    @Binding var choice: AddPageChoice
    /// Adds a page of this paper at the chosen position, then the popover closes.
    let add: (PaperTemplate) -> Void
    @State private var showsTemplates: Bool

    /// `showsTemplates` opens the popover on More Templates (screenshots use it).
    init(choice: Binding<AddPageChoice>, showsTemplates: Bool = false, add: @escaping (PaperTemplate) -> Void) {
        _choice = choice
        self.add = add
        _showsTemplates = State(initialValue: showsTemplates)
    }

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

/// More Templates: size, orientation, colour and paper, then Apply. More › Change Template uses it too (EP62).
struct PaperTemplatePicker: View {
    let title: String
    let apply: (PaperTemplate) -> Void
    @State private var template: PaperTemplate

    init(initial: PaperTemplate, title: String = "Templates", apply: @escaping (PaperTemplate) -> Void) {
        self.title = title
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") { apply(template) }.fontWeight(.semibold)
            }
        }
    }
}
