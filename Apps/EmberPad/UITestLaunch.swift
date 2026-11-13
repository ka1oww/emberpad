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
