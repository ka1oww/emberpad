import EmberSyncKit
import PencilKit
import UIKit

#if DEBUG
/// Debug builds only: what `EmberPadUITests` launches the app with. A launch with `-EmberPadUITestWorksheet` starts
/// from a fresh library holding one synthetic worksheet, filed from the Inbox as any loose PDF is, with the tool row
/// and Teacher copy panel in their first-launch places. Nothing here runs without that argument, and Release builds
/// do not contain it.
enum UITestLaunch {
    static let worksheetArgument = "-EmberPadUITestWorksheet"
    /// The class folder and title the synthetic worksheet is filed under.
    static let className = "UI Test"
    static let title = "Toolbar Drag"

    /// Call before the library opens.
    static func prepareIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(worksheetArgument) else { return }
        let files = FileManager.default
        guard let support = try? files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
              let documents = try? files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        for name in ["Library", "Sync", "Backup"] { try? files.removeItem(at: support.appendingPathComponent(name)) }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try? files.removeItem(at: inbox)
        for key in [ToolState.defaultsKey, LastWorksheet.defaultsKey, TeacherCopyCardState.defaultsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let folder = inbox.appendingPathComponent(className, isDirectory: true)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? worksheet().write(to: folder.appendingPathComponent("\(title).pdf"))
    }

    /// EP108: launched with this as well, the worksheet opens with a few lines of pen ink on its first page, so a
    /// real-touch test can work a finger on a page that holds ink. Only in memory: nothing is saved unless the test
    /// writes.
    static let inkArgument = "-EmberPadUITestInk"

    /// `drawings` as `record` opens with them: the seeded ink on the first page, when launched for it.
    static func drawings(_ drawings: [Int: PKDrawing], for record: DocumentRecord) -> [Int: PKDrawing] {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(worksheetArgument), arguments.contains(inkArgument), record.title.hasPrefix(title),
              drawings[0]?.strokes.isEmpty ?? true else { return drawings }
        var seeded = drawings
        seeded[0] = PKDrawing(strokes: handwriting())
        return seeded
    }

    /// Five short wavy words on each of the first three ruled lines, in page points.
    private static func handwriting() -> [PKStroke] {
        let ink = PKInk(.pen, color: .black)
        var strokes: [PKStroke] = []
        for row in 1...3 {
            let line = 130 + CGFloat(row) * 28
            for word in 0..<5 {
                let left = 70 + CGFloat(word) * 95
                let points = (0...24).map { k -> PKStrokePoint in
                    let t = CGFloat(k) / 24
                    return PKStrokePoint(location: CGPoint(x: left + 70 * t, y: line - 10 - 7 * sin(t * .pi * 6)),
                                         timeOffset: Double(k) * 0.01, size: CGSize(width: 2.5, height: 2.5), opacity: 1,
                                         force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
        }
        return strokes
    }

    /// Two A4 pages with a heading and ruled lines.
    private static func worksheet() -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for number in 1...2 {
                context.beginPage()
                let heading = "\(title) · page \(number)" as NSString
                heading.draw(at: CGPoint(x: 56, y: 56), withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .semibold)])
                UIColor.lightGray.setStroke()
                for row in 0..<24 {
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: 56, y: 130 + CGFloat(row) * 28))
                    line.addLine(to: CGPoint(x: page.width - 56, y: 130 + CGFloat(row) * 28))
                    line.stroke()
                }
            }
        }
    }
}
#endif
