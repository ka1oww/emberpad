import AppKit
import EmberSyncKit
import IOKit.pwr_mgt
import PDFKit
import PencilKit
import QuartzCore
import SwiftUI

/// Present on Mac, the Mac side (EP93). The sync server hands every PRESENT frame to `host`; this model shows what
/// it holds in a presentation window: full screen on the projector (the first display that is not the Mac's own,
/// unless another is chosen), or a normal window when the Mac has no other display. The window opens when the iPad
/// starts presenting and closes when it stops. While it is up the Mac's display does not sleep.
@MainActor
final class CompanionPresentModel: ObservableObject {
    static let displayKey = "EmberPadCompanion.presentDisplayName"

    @Published private(set) var status: PresentHost.Status = .off
    /// The display chosen in the menu, by name; empty means automatic.
    @Published var displayChoice: String {
        didSet {
            UserDefaults.standard.set(displayChoice, forKey: Self.displayKey)
            if status != .off, !hidden { showWindow() }
        }
    }
    @Published private(set) var screenNames: [String] = []
    /// The teacher hid the window from the menu; the next Present shows it again.
    @Published private(set) var hidden = false

    let host: PresentHost
    private let mailbox: PresentMailbox
    private let window = PresentWindowController()
    private var ticker: Timer?
    private var screenObserver: NSObjectProtocol?
    private var sleepAssertion: IOPMAssertionID?

    init() {
        let mailbox = PresentMailbox()
        let box = WeakPresentModel()
        host = PresentHost(onChange: { scene, status in
            // Called on the server's queue for every update; the main thread draws only the latest.
            if mailbox.put(scene, status) {
                DispatchQueue.main.async { MainActor.assumeIsolated { box.model?.drain() } }
            }
        })
        self.mailbox = mailbox
        displayChoice = UserDefaults.standard.string(forKey: Self.displayKey) ?? ""
        box.model = self
        window.onHide = { [weak self] in self?.hide() }
        refreshScreens()
        let host = self.host
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in host.tick() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshScreens()
                if let self, self.status != .off, !self.hidden { self.showWindow() }
            }
        }
    }

    var statusText: String {
        switch status {
        case .off: "Not presenting. Turn on Present on Mac in EmberPad on the iPad."
        case .connected: "Presenting from the iPad"
        case .reconnecting: "Reconnecting to the iPad…"
        }
    }

    var statusColor: Color? {
        switch status {
        case .connected: .green
        case .reconnecting: .orange
        case .off: nil
        }
    }

    /// **Hide presentation**: closes the window until the iPad presents again or **Show presentation**.
    func hide() {
        hidden = true
        window.close()
        releaseSleep()
    }

    func show() {
        hidden = false
        guard status != .off else { return }
        showWindow()
        window.render(host.current, status: status)
    }

    private func drain() {
        guard let (scene, status) = mailbox.take() else { return }
        let started = self.status == .off && status != .off
        self.status = status
        if status == .off {
            hidden = false
            window.close()
            releaseSleep()
            return
        }
        if started { hidden = false }
        guard !hidden else { return }
        if !window.isShown { showWindow() }
        window.render(scene, status: status)
    }

    private func showWindow() {
        window.show(on: targetScreen())
        holdSleep()
    }

    private func refreshScreens() {
        screenNames = NSScreen.screens.map(\.localizedName)
    }

    /// The chosen display, else the first that is not built in (the projector), else the main display.
    func targetScreen() -> NSScreen? {
        if !displayChoice.isEmpty, let chosen = NSScreen.screens.first(where: { $0.localizedName == displayChoice }) {
            return chosen
        }
        return NSScreen.screens.first { !$0.isBuiltIn } ?? NSScreen.main
    }

    private func holdSleep() {
        guard sleepAssertion == nil else { return }
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "EmberPad Present on Mac" as CFString, &id) == kIOReturnSuccess {
            sleepAssertion = id
        }
    }

    private func releaseSleep() {
        guard let id = sleepAssertion else { return }
        IOPMAssertionRelease(id)
        sleepAssertion = nil
    }
}

private final class WeakPresentModel: @unchecked Sendable {
    weak var model: CompanionPresentModel?
}

/// The newest scene from the server's queue, waiting for the main thread. `put` says whether a drain must be
/// scheduled, so a burst of updates schedules one.
final class PresentMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (PresentScene, PresentHost.Status)?
    private var scheduled = false

    func put(_ scene: PresentScene, _ status: PresentHost.Status) -> Bool {
        lock.withLock {
            latest = (scene, status)
            defer { scheduled = true }
            return !scheduled
        }
    }

    func take() -> (PresentScene, PresentHost.Status)? {
        lock.withLock {
            scheduled = false
            defer { latest = nil }
            return latest
        }
    }
}

extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}

// MARK: - Window

/// The presentation window. On a projector it is borderless and covers the whole display above the menu bar and
/// Dock, so the class sees only the worksheet. On the Mac's own display it is an ordinary window that can go full
/// screen, so the Mac stays usable. Esc or Close hides it.
@MainActor
final class PresentWindowController: NSObject, NSWindowDelegate {
    var onHide: (() -> Void)?
    private var window: NSWindow?
    private var coversScreen = false
    let canvas = PresentCanvasView()

    var isShown: Bool { window?.isVisible == true }

    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let cover = !screen.isBuiltIn
        if let window, coversScreen == cover, !cover || window.screen == screen {
            if cover { window.setFrame(screen.frame, display: true) }
            window.orderFrontRegardless()
            return
        }
        window?.delegate = nil
        window?.orderOut(nil)
        canvas.removeFromSuperview()
        let made: NSWindow
        if cover {
            made = PresentWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            made.level = .screenSaver
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            made.setFrame(screen.frame, display: false)
            made.hasShadow = false
        } else {
            let size = CGSize(width: min(1_280, screen.visibleFrame.width * 0.8), height: min(800, screen.visibleFrame.height * 0.8))
            made = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
            made.title = "EmberPad Presentation"
            made.collectionBehavior = [.fullScreenPrimary]
            made.center()
        }
        made.isReleasedWhenClosed = false
        made.backgroundColor = .black
        made.delegate = self
        canvas.onEscape = { [weak self] in self?.onHide?() }
        made.contentView = canvas
        coversScreen = cover
        window = made
        if cover {
            made.orderFrontRegardless()
            made.makeKey()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            made.makeKeyAndOrderFront(nil)
        }
        made.makeFirstResponder(canvas)
    }

    func close() {
        window?.orderOut(nil)
    }

    func render(_ scene: PresentScene, status: PresentHost.Status) {
        canvas.render(scene, status: status)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onHide?()
        return false
    }
}

/// A borderless window that still takes keys, for Esc.
private final class PresentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - Canvas

/// Draws a `PresentScene` exactly as the iPad's student view draws its `PresentedView`: the shown rect aspect-fitted
/// on black, each page's paper as a cached bitmap, its ink multiplied over it, then strokes in progress as vector
/// paths, the laser trail and the dot. A Pencil move changes only paths; ink appended to a page renders only the new
/// strokes; a scroll moves layers without rasterising anything.
final class PresentCanvasView: NSView {
    var onEscape: (() -> Void)?

    private let root = CALayer()
    private let viewport = CALayer()
    private let liveLayer = CALayer()
    private var liveShapes: [CAShapeLayer] = []
    private var trailCores: [CAShapeLayer] = []
    private var trailGlows: [CAShapeLayer] = []
    private let laserLayer = CALayer()
    private let message = CATextLayer()
    private let star = CAShapeLayer()
    private let statusDot = CALayer()
    private var pages: [Int: PresentPageLayers] = [:]
    private var paperImages = PresentPaperImages()
    private var scene: PresentScene?
    private var status = PresentHost.Status.off

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.backgroundColor = NSColor.black.cgColor
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        viewport.masksToBounds = true
        // The gaps between straddled pages match the worksheet canvas, as on the iPad's student view.
        viewport.backgroundColor = CGColor(srgbRed: 0.906, green: 0.886, blue: 0.851, alpha: 1)
        root.addSublayer(viewport)
        liveLayer.zPosition = 10
        viewport.addSublayer(liveLayer)
        for index in 0..<PresentLaserStyle.fadeLevels {
            let glow = CAShapeLayer(), core = CAShapeLayer()
            for shape in [glow, core] {
                shape.fillColor = nil
                shape.strokeColor = PresentLaserStyle.color
                shape.lineCap = .round
                shape.lineJoin = .round
                liveLayer.addSublayer(shape)
            }
            glow.opacity = PresentLaserStyle.glowOpacity * Float(index + 1) / Float(PresentLaserStyle.fadeLevels)
            core.opacity = Float(index + 1) / Float(PresentLaserStyle.fadeLevels)
            trailGlows.append(glow)
            trailCores.append(core)
        }
        laserLayer.isHidden = true
        laserLayer.zPosition = 20
        liveLayer.addSublayer(laserLayer)
        message.alignmentMode = .center
        message.foregroundColor = NSColor.white.cgColor
        message.isHidden = true
        root.addSublayer(message)
        star.fillColor = CGColor(srgbRed: 0xB2 / 255, green: 0x3A / 255, blue: 0x2E / 255, alpha: 1)
        star.isHidden = true
        root.addSublayer(star)
        statusDot.zPosition = 100
        statusDot.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        statusDot.borderWidth = 1
        root.addSublayer(statusDot)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    func render(_ scene: PresentScene, status: PresentHost.Status) {
        self.scene = scene
        self.status = status
        redraw()
    }

    private var screenScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = bounds
        let screen = scene?.presented?.screen ?? .idle
        viewport.isHidden = true
        message.isHidden = true
        star.isHidden = true
        switch screen {
        case .idle: showStar()
        case .paused: show(message: "Paused")
        case .teacherCopyPrivate: show(message: "Teacher copy · private")
        case .page(let page): layout(page)
        }
        if case .page = screen {} else { dropPages(keeping: []) }
        layoutStatusDot()
    }

    private func show(message text: String) {
        let size = max(28, min(bounds.width, bounds.height) * 0.06)
        message.string = text
        message.font = NSFont.systemFont(ofSize: size, weight: .semibold)
        message.fontSize = size
        message.contentsScale = screenScale
        message.frame = CGRect(x: 0, y: bounds.midY - size * 0.7, width: bounds.width, height: size * 1.4)
        message.isHidden = false
    }

    /// The Ember star alone on black, as the iPad's student view shows the library (EP92).
    private func showStar() {
        let height = min(bounds.height * 0.16, bounds.width * 0.16 / PresentStar.aspectRatio)
        star.path = PresentStar.path(in: CGRect(x: bounds.midX - height * PresentStar.aspectRatio / 2, y: bounds.midY - height / 2,
                                                width: height * PresentStar.aspectRatio, height: height))
        star.isHidden = false
    }

    private func layoutStatusDot() {
        let color: CGColor? = switch status {
        case .connected: CGColor(srgbRed: 0.184, green: 0.69, blue: 0.31, alpha: 1)
        case .reconnecting: CGColor(srgbRed: 0.95, green: 0.62, blue: 0.1, alpha: 1)
        case .off: nil
        }
        statusDot.isHidden = color == nil
        statusDot.backgroundColor = color
        let size: CGFloat = 10
        statusDot.frame = CGRect(x: bounds.maxX - size - 14, y: bounds.maxY - size - 14, width: size, height: size)
        statusDot.cornerRadius = size / 2
        statusDot.opacity = 0.85
    }

    private func layout(_ page: PresentedView.Page) {
        guard let scene else { return }
        let target = PresentGeometry.aspectFit(page.visibleRect.size, in: bounds, margin: page.margin)
        guard !target.isEmpty else { return dropPages(keeping: []) }
        viewport.isHidden = false
        viewport.frame = target
        let local = CGRect(origin: .zero, size: target.size)
        liveLayer.frame = local
        let refs = Dictionary((scene.frame?.pages ?? []).map { ($0.pageIndex, $0) }, uniquingKeysWith: { a, _ in a })
        var placed: [Int: (frame: CGRect, pageSize: CGSize)] = [:]
        for item in page.pages {
            let frame = PresentGeometry.map(item.frame, from: page.visibleRect, to: local)
            let ref = refs[item.pageIndex]
            let pageSize = ref?.size ?? item.frame.size
            placed[item.pageIndex] = (frame, pageSize)
            let layers = pages[item.pageIndex] ?? {
                let made = PresentPageLayers()
                viewport.insertSublayer(made.paper, below: liveLayer)
                viewport.insertSublayer(made.ink, below: liveLayer)
                pages[item.pageIndex] = made
                return made
            }()
            layers.paper.frame = frame
            layers.ink.frame = frame
            let scale = PresentGeometry.rasterScale(pageSize: pageSize, displayedPoints: frame.width, screenScale: screenScale)
            if let ref, let asset = scene.asset(for: ref.asset) {
                layers.paper.contents = paperImages.image(for: asset, pageSize: pageSize, scale: scale)
            } else {
                layers.paper.contents = nil
            }
            layers.update(ink: scene.ink[item.pageIndex], pageSize: pageSize, scale: scale, frame: frame)
        }
        dropPages(keeping: Set(placed.keys))
        layoutLive(page, placed: placed, size: local.size)
    }

    private func dropPages(keeping kept: Set<Int>) {
        for (index, layers) in pages where !kept.contains(index) {
            layers.paper.removeFromSuperlayer()
            layers.ink.removeFromSuperlayer()
            pages[index] = nil
        }
        if kept.isEmpty {
            for shape in liveShapes { shape.isHidden = true }
            laserLayer.isHidden = true
            for shape in trailCores + trailGlows { shape.path = nil }
        }
    }

    private func layoutLive(_ page: PresentedView.Page, placed: [Int: (frame: CGRect, pageSize: CGSize)], size: CGSize) {
        while liveShapes.count < page.liveStrokes.count {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
            liveLayer.insertSublayer(shape, at: 0)
            liveShapes.append(shape)
        }
        for (index, shape) in liveShapes.enumerated() {
            guard index < page.liveStrokes.count, let place = placed[page.liveStrokes[index].pageIndex],
                  place.pageSize.width > 0 else {
                shape.isHidden = true
                shape.path = nil
                continue
            }
            let stroke = page.liveStrokes[index]
            let rgba = stroke.rgba.count == 4 ? stroke.rgba : [0, 0, 0, 1]
            shape.isHidden = false
            shape.strokeColor = CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
            shape.lineWidth = stroke.width * place.frame.width / place.pageSize.width
            shape.path = PresentGeometry.path(PresentGeometry.map(stroke.points, pageSize: place.pageSize, onto: place.frame))
        }
        // The laser trail, drawn in opacity steps like the iPad's.
        let width = PresentLaserStyle.trailWidth(for: size)
        let cores = (0..<PresentLaserStyle.fadeLevels).map { _ in CGMutablePath() }
        for piece in page.laserTrail {
            guard let place = placed[piece.pageIndex] else { continue }
            let ends = PresentGeometry.map([piece.from, piece.to], pageSize: place.pageSize, onto: place.frame)
            let level = min(PresentLaserStyle.fadeLevels - 1, max(0, Int((piece.opacity * Double(PresentLaserStyle.fadeLevels)).rounded(.up)) - 1))
            guard piece.opacity > 0 else { continue }
            cores[level].move(to: ends[0])
            cores[level].addLine(to: ends[1])
        }
        for index in 0..<PresentLaserStyle.fadeLevels {
            trailCores[index].path = cores[index]
            trailCores[index].lineWidth = width
            trailGlows[index].path = cores[index]
            trailGlows[index].lineWidth = width * PresentLaserStyle.glowScale
        }
        // The dot.
        if let laser = page.laser, let place = placed[laser.pageIndex],
           let center = PresentGeometry.map([laser.location], pageSize: place.pageSize, onto: place.frame).first,
           place.frame.contains(center) {
            PresentLaserStyle.style(laserLayer, diameter: PresentLaserStyle.dotDiameter(for: size))
            laserLayer.position = center
            laserLayer.isHidden = false
        } else {
            laserLayer.isHidden = true
        }
    }

    /// The window's picture, for screenshots in tests and the PR.
    func snapshotImage() -> CGImage? {
        let scale = screenScale
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        root.render(in: context)
        return context.makeImage()
    }
}

/// One shown page: its paper, and its ink as one layer per rendered segment (only what was appended renders).
final class PresentPageLayers {
    let paper = CALayer()
    let ink = CALayer()
    private var generation: UInt64?
    private var scale: CGFloat = 0
    private var rendered = 0
    /// Each segment layer's rect in page points.
    private var segments: [(layer: CALayer, bounds: CGRect)] = []
    /// When a page holds more segment layers than this, they are rendered again as one.
    static let maxSegmentLayers = 24

    init() {
        paper.backgroundColor = NSColor.white.cgColor
        for layer in [paper, ink] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .trilinear
        }
    }

    func update(ink held: PresentScene.Ink?, pageSize: CGSize, scale: CGFloat, frame: CGRect) {
        guard let held, pageSize.width > 0 else {
            clear()
            return
        }
        let page = CGRect(origin: .zero, size: pageSize)
        if held.generation != generation || scale != self.scale || held.segments.count < rendered {
            clear()
            generation = held.generation
            self.scale = scale
        }
        if held.segments.count > rendered {
            let fresh = held.segments[rendered...]
            if segments.count + fresh.count > Self.maxSegmentLayers {
                clear()
                generation = held.generation
                self.scale = scale
                add(drawing: Self.drawing(held.segments[...]), page: page, scale: scale)
            } else {
                for data in fresh { add(drawing: Self.drawing([data][...]), page: page, scale: scale) }
            }
            rendered = held.segments.count
        }
        let k = frame.width / pageSize.width
        for segment in segments {
            segment.layer.frame = CGRect(x: segment.bounds.minX * k, y: segment.bounds.minY * k,
                                         width: segment.bounds.width * k, height: segment.bounds.height * k)
        }
    }

    private func clear() {
        for segment in segments { segment.layer.removeFromSuperlayer() }
        segments = []
        rendered = 0
        generation = nil
    }

    private func add(drawing: PKDrawing, page: CGRect, scale: CGFloat) {
        let bounds = drawing.bounds.intersection(page).integral.intersection(page)
        guard !drawing.strokes.isEmpty, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        var image: CGImage?
        // Ink keeps its light-appearance colours, as on the iPad's pages.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            image = drawing.image(from: bounds, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        // The ink multiplies into its page, as on the iPad (EP71).
        layer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        ink.addSublayer(layer)
        segments.append((layer, bounds))
    }

    static func drawing(_ parts: ArraySlice<Data>) -> PKDrawing {
        var drawing = PKDrawing()
        for data in parts {
            if let part = try? PKDrawing(data: data) { drawing.append(part) }
        }
        return drawing
    }
}

/// Page bitmaps by paper and scale, a few kept.
struct PresentPaperImages {
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    static let capacity = 8

    mutating func image(for asset: PresentAsset, pageSize: CGSize, scale: CGFloat) -> CGImage? {
        let key = "\(asset.hash)@\(scale)"
        if let image = cache[key] { return image }
        guard let image = Self.rasterise(asset, pageSize: pageSize, scale: scale) else { return nil }
        cache[key] = image
        order.append(key)
        while order.count > Self.capacity { cache[order.removeFirst()] = nil }
        return image
    }

    /// A white, opaque bitmap of the page at `scale` pixels per point (a JPEG is used as it came).
    static func rasterise(_ asset: PresentAsset, pageSize: CGSize, scale: CGFloat) -> CGImage? {
        switch asset.kind {
        case .jpeg:
            guard let source = CGImageSourceCreateWithData(asset.bytes as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .pdf:
            // The document must outlive the drawing: PDFKit does not support drawing a page whose document is gone.
            guard let document = PDFDocument(data: asset.bytes), let page = document.page(at: 0) else { return nil }
            let width = Int((pageSize.width * scale).rounded()), height = Int((pageSize.height * scale).rounded())
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            // PDFKit applies the page's rotation, as it does on the iPad.
            withExtendedLifetime(document) { page.draw(with: .cropBox, to: context) }
            return context.makeImage()
        }
    }
}

// MARK: - Geometry and style, as the iPad's student view uses them

/// The same arithmetic as the iPad's `MirrorGeometry` and `LiveInkGeometry`, so both screens frame a page alike.
enum PresentGeometry {
    static let maxRasterSide: CGFloat = 4_096

    static func aspectFit(_ content: CGSize, in bounds: CGRect, margin: CGFloat = 0) -> CGRect {
        let area = bounds.insetBy(dx: bounds.width * margin, dy: bounds.height * margin)
        guard content.width > 0, content.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / content.width, area.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func map(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0 else { return .zero }
        let scale = target.width / source.width
        return CGRect(x: target.minX + (rect.minX - source.minX) * scale, y: target.minY + (rect.minY - source.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    static func map(_ points: [CGPoint], pageSize: CGSize, onto frame: CGRect) -> [CGPoint] {
        guard pageSize.width > 0 else { return [] }
        let scale = frame.width / pageSize.width
        return points.map { CGPoint(x: frame.minX + $0.x * scale, y: frame.minY + $0.y * scale) }
    }

    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first) } else { path.addLines(between: points) }
        return path
    }

    /// Pixels per page point, rounded up to a power of two so scrolling reuses bitmaps, capped by `maxRasterSide`.
    static func rasterScale(pageSize: CGSize, displayedPoints: CGFloat, screenScale: CGFloat) -> CGFloat {
        let longest = max(pageSize.width, pageSize.height)
        guard pageSize.width > 0, longest > 0, displayedPoints > 0, screenScale > 0 else { return 1 }
        let wanted = displayedPoints / pageSize.width * screenScale
        let bucket = pow(2, ceil(log2(max(wanted, 0.125))))
        return min(bucket, maxRasterSide / longest)
    }
}

enum PresentLaserStyle {
    static let color = CGColor(srgbRed: 1, green: 0.16, blue: 0.12, alpha: 1)
    static let fadeLevels = 10
    static let glowScale: CGFloat = 3.2
    static let glowOpacity: Float = 0.35

    static func dotDiameter(for shown: CGSize) -> CGFloat { max(12, min(shown.width, shown.height) * 0.022) }
    static func trailWidth(for shown: CGSize) -> CGFloat { max(4, min(shown.width, shown.height) * 0.008) }

    static func style(_ layer: CALayer, diameter: CGFloat) {
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = color
        layer.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer.borderWidth = max(1, diameter / 10)
        layer.shadowColor = color
        layer.shadowOpacity = 0.9
        layer.shadowRadius = diameter * 0.6
        layer.shadowOffset = .zero
    }
}

/// The Ember star outline, as `EmberStar` draws it on the iPad.
enum PresentStar {
    static let aspectRatio: CGFloat = 2 * 0.4062
    static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.0966, y: 0.0716), CGPoint(x: 0.4062, y: 0), CGPoint(x: 0.0966, y: -0.0716),
        CGPoint(x: 0, y: -0.5), CGPoint(x: -0.0966, y: -0.0716), CGPoint(x: -0.4062, y: 0), CGPoint(x: -0.0966, y: 0.0716),
    ]

    static func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.height, rect.width / aspectRatio)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGMutablePath()
        for (index, point) in outline.enumerated() {
            let mapped = CGPoint(x: center.x + point.x * scale, y: center.y - point.y * scale)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Menu

/// The Companion window's Present section: the light, which display, and Hide or Show.
struct CompanionPresentSection: View {
    @ObservedObject var model: CompanionPresentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Present on Mac").font(.headline)
            HStack(spacing: 6) {
                Circle().fill(model.statusColor ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(model.statusText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Show on", selection: $model.displayChoice) {
                Text("Automatic (projector when connected)").tag("")
                ForEach(model.screenNames, id: \.self) { Text($0).tag($0) }
            }
            if model.status != .off {
                Button(model.hidden ? "Show presentation" : "Hide presentation") {
                    if model.hidden { model.show() } else { model.hide() }
                }
            }
        }
        .padding(14)
    }
}
