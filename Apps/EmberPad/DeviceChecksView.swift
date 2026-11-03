#if DEBUG
import SwiftUI
import PDFKit
import PencilKit

/// EP-03 Phase 0 device-check probe screen (Debug only, unreachable in Release).
///
/// Device diagnostics and a separate debug-only scribble recorder. Diagnostic
/// snapshots are appended to `Documents/device-checks.log` when they change;
/// recorded scribble samples are exported separately as JSON.
/// EP-04 adds one more section here (peer-to-peer); add it as a new `Section`
/// below without touching the existing ones.
struct DeviceChecksView: View {
    @ObservedObject var presentation: PresentationState
    @ObservedObject private var externalTest = DeviceChecksExternalTest.shared
    @State private var captureState = UISceneCaptureState.unspecified
    @State private var pencilLabel = "Reading…"
    @State private var logWritable = true
    @State private var lastLogged: DeviceChecksSnapshot?
    @State private var lastLogError: String?
    @State private var zoom: CGFloat = 1
    @State private var testTool = DeviceChecksPDFTool.ink
    @State private var testPDFOK = false
    @State private var scribbleDrawing = PKDrawing()
    @State private var scribbleLabel = ScribbleLabel.keep
    @State private var scribbleSamples: [ScribbleSample] = []
    @State private var scribbleClearToken = 0
    @State private var scribbleExportURL: URL?
    @State private var scribbleError: String?

    private var snapshot: DeviceChecksSnapshot {
        DeviceChecksSnapshot(
            captureState: DeviceChecksSnapshot.captureStateLabel(captureState),
            externalSceneCount: presentation.externalSceneCount,
            mainSceneActive: presentation.mainSceneActive,
            screenCount: UIScreen.screens.count,
            screenCaptured: UIScreen.screens.contains(where: \.isCaptured)
        )
    }

    var body: some View {
        List {
            Section("External display") {
                Toggle("Show test colour on external display", isOn: $externalTest.isEnabled)
                LabeledValue(label: "External scenes", value: "\(presentation.externalSceneCount)")
                LabeledValue(label: "Main scene", value: presentation.mainSceneActive ? "active" : "inactive")
                Text("When the toggle is on, the external scene shows a solid test colour plus its role.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Capture state") {
                SceneCaptureReader(state: $captureState).frame(width: 0, height: 0).hidden()
                LabeledValue(label: "sceneCaptureState", value: DeviceChecksSnapshot.captureStateLabel(captureState))
                LabeledValue(label: "Screens", value: "\(UIScreen.screens.count)")
                LabeledValue(label: "Screen captured", value: snapshot.screenCaptured ? "yes" : "no")
            }
            Section("Check log") {
                LabeledValue(label: "File", value: "Documents/\(DeviceChecksLog.fileName)")
                if let error = lastLogError {
                    Text("Log write failed: \(error)").foregroundStyle(.red).font(.footnote)
                } else {
                    Text("Every change above is appended with a timestamp.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Writing trial (synthetic test PDF)") {
                Picker("Zoom", selection: $zoom) {
                    Text("1x").tag(CGFloat(1))
                    Text("2x").tag(CGFloat(2))
                }.pickerStyle(.segmented)
                Picker("Tool", selection: $testTool) {
                    ForEach(DeviceChecksPDFTool.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                DeviceChecksPDFTestHost(zoom: zoom, tool: testTool)
                    .frame(minHeight: 420)
                Text("Write at 1x and 2x. Choose Lasso, circle ink, and tap the selection to try the system menu.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Scribble sample recorder (EP-27)") {
                DeviceChecksScribbleCanvas(drawing: $scribbleDrawing, clearToken: scribbleClearToken)
                    .frame(height: 260)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
                Picker("Label", selection: $scribbleLabel) {
                    ForEach(ScribbleLabel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Button("Save sample") { saveScribbleSample() }
                        .disabled(scribbleDrawing.strokes.isEmpty)
                    Button("Clear canvas") { scribbleClearToken += 1 }
                    Spacer()
                    Button("Export JSON") { exportScribbleSamples() }
                        .disabled(scribbleSamples.isEmpty)
                }.buttonStyle(.bordered)
                LabeledValue(label: "Saved samples",
                             value: "\(scribbleSamples.count) (erase \(scribbleSamples.filter { $0.label == .erase }.count), keep \(scribbleSamples.filter { $0.label == .keep }.count))")
                if let error = scribbleError {
                    Text("Export failed: \(error)").foregroundStyle(.red).font(.footnote)
                } else {
                    Text("Draw, pick erase or keep, save, then export through Files. Nothing is uploaded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Apple Pencil") {
                LabeledValue(label: "Double-tap action", value: pencilLabel)
            }
            Section("Pass / fail") {
                ForEach(passFailRows, id: \.title) { row in
                    HStack {
                        statusDot(row.passed)
                        VStack(alignment: .leading) {
                            Text(row.title).font(.headline)
                            Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.passed ? "Pass" : "Fail")
                            .font(.footnote).bold()
                            .foregroundStyle(row.passed ? .green : .red)
                    }
                }
            }
            // EP-04 (peer-to-peer) adds one more Section here.
        }
        .navigationTitle("Device checks")
        .onAppear {
            pencilLabel = DeviceChecksPencil.currentLabel
            testPDFOK = PDFDocument(data: DeviceChecksTestPDF.data())?.pageCount == 2
            appendSnapshot(force: true)
        }
        .onChange(of: snapshot) { _, _ in appendSnapshot() }
        .sheet(item: $scribbleExportURL) { url in
            DeviceChecksExportPicker(url: url).ignoresSafeArea()
        }
    }

    private func saveScribbleSample() {
        guard !scribbleDrawing.strokes.isEmpty else { return }
        scribbleSamples.append(ScribbleSample(label: scribbleLabel, drawing: scribbleDrawing))
        scribbleClearToken += 1
    }

    private func exportScribbleSamples() {
        do {
            scribbleExportURL = try ScribbleSampleCodec.writeExport(ScribbleSampleSet(samples: scribbleSamples))
            scribbleError = nil
        } catch {
            scribbleError = error.localizedDescription
        }
    }

    private var passFailRows: [DeviceCheckResult] {
        DeviceChecksEvaluator.results(
            snapshot: snapshot, logWritable: logWritable, testPDFOK: testPDFOK, pencilReadable: true)
    }

    private func appendSnapshot(force: Bool = false) {
        let current = snapshot
        guard force || current.differs(from: lastLogged) else { return }
        lastLogged = current
        guard let documents = DeviceChecksLog.documentsURL() else {
            logWritable = false
            lastLogError = "Documents directory unavailable"
            return
        }
        do {
            try DeviceChecksLog.append(DeviceChecksLog.line(date: Date(), snapshot: current), documentsURL: documents)
            logWritable = true
            lastLogError = nil
        } catch {
            logWritable = false
            lastLogError = error.localizedDescription
        }
    }

    private func statusDot(_ passed: Bool) -> some View {
        Circle()
            .fill(passed ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced()
        }.font(.footnote)
    }
}

// MARK: - Scribble sample recorder (EP-27)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Plain PKCanvasView that accepts any input so samples can be drawn in the
/// Simulator as well as with the Pencil. Bumping `clearToken` empties it.
private struct DeviceChecksScribbleCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let clearToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        canvas.backgroundColor = .secondarySystemBackground
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if context.coordinator.lastClearToken != clearToken {
            context.coordinator.lastClearToken = clearToken
            canvas.drawing = PKDrawing()
            DispatchQueue.main.async { drawing = PKDrawing() }
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DeviceChecksScribbleCanvas
        var lastClearToken: Int
        init(_ parent: DeviceChecksScribbleCanvas) {
            self.parent = parent
            self.lastClearToken = parent.clearToken
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

/// Files export sheet for the generated JSON (copy to a chosen location).
private struct DeviceChecksExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - External test pattern (shown on the external scene)

/// Solid test colour plus its role, shown on the external display while the
/// Device checks toggle is on. The Simulator's external display shows this.
struct DeviceChecksExternalTestView: View {
    var body: some View {
        ZStack {
            Color(DeviceChecksExternalTest.testColor)
            VStack(spacing: 12) {
                Text("Device-check test pattern").font(.largeTitle).bold()
                Text("Role: \(DeviceChecksExternalTest.externalRoleLabel)").font(.headline)
                Text("If you see this solid colour, the external scene works.").font(.footnote)
            }.foregroundStyle(.white)
        }.ignoresSafeArea()
    }
}

// MARK: - sceneCaptureState bridge

/// Reports the hosting controller's `traitCollection.sceneCaptureState`.
/// Mirrors the trait registration in `CaptureGuardHostingController`.
private struct SceneCaptureReader: UIViewControllerRepresentable {
    @Binding var state: UISceneCaptureState
    func makeUIViewController(context: Context) -> ReaderController {
        ReaderController { state = $0 }
    }
    func updateUIViewController(_ uiViewController: ReaderController, context: Context) {
        uiViewController.report()
    }

    final class ReaderController: UIViewController {
        private let onChange: (UISceneCaptureState) -> Void
        init(onChange: @escaping (UISceneCaptureState) -> Void) {
            self.onChange = onChange
            super.init(nibName: nil, bundle: nil)
        }
        @MainActor required dynamic init?(coder: NSCoder) { nil }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isHidden = true
            registerForTraitChanges([UITraitSceneCaptureState.self]) { (controller: ReaderController, _: UITraitCollection) in
                controller.report()
            }
            report()
        }
        func report() { onChange(traitCollection.sceneCaptureState) }
    }
}

// MARK: - Synthetic-PDF writing trial

enum DeviceChecksPDFTool: CaseIterable {
    case ink, lasso
    var title: String {
        switch self {
        case .ink: return "Ink"
        case .lasso: return "Lasso"
        }
    }
}

/// Same stack as the worksheet page view (PDFView + per-page PKCanvasView +
/// PKToolPicker with a lasso item), pointed at the generated test PDF so the
/// 1x/2x writing trial and the system lasso menu can be tried here.
private struct DeviceChecksPDFTestHost: UIViewControllerRepresentable {
    let zoom: CGFloat
    let tool: DeviceChecksPDFTool
    func makeUIViewController(context: Context) -> DeviceChecksPDFTestController {
        DeviceChecksPDFTestController()
    }
    func updateUIViewController(_ uiViewController: DeviceChecksPDFTestController, context: Context) {
        uiViewController.setZoom(zoom)
        uiViewController.select(tool)
    }
}

private final class DeviceChecksPDFTestController: UIViewController, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    private let pdfView = PDFView()
    private var canvases: [Int: PKCanvasView] = [:]
    private let picker = PKToolPicker()
    private var document: PDFDocument?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor), pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        document = PDFDocument(data: DeviceChecksTestPDF.data())
        pdfView.pageOverlayViewProvider = self // Must precede document assignment.
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.displayBox = .cropBox
        pdfView.document = document
        applyZoom(1)
    }

    func setZoom(_ zoom: CGFloat) { applyZoom(zoom) }

    private func applyZoom(_ zoom: CGFloat) {
        guard isViewLoaded else { return }
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * max(1, zoom)
    }

    func select(_ tool: DeviceChecksPDFTool) {
        let pencilTool: PKTool
        switch tool {
        case .ink: pencilTool = PKInkingTool(.pen, color: .black, width: 2)
        case .lasso: pencilTool = PKLassoTool()
        }
        picker.selectedTool = pencilTool
        for canvas in canvases.values { canvas.tool = pencilTool }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        if let existing = canvases[index] { return existing }
        let canvas = PKCanvasView(frame: CGRect(origin: .zero, size: page.bounds(for: .cropBox).size))
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = self
        picker.addObserver(canvas)
        canvases[index] = canvas
        return canvas
    }
}
#endif
