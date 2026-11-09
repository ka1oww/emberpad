#if DEBUG
import Foundation
import PencilKit

/// EP-27 debug scribble sample recorder: non-UI core.
///
/// A sample is one PencilKit drawing the captain labelled `erase` (a scribble
/// meant to rub something out) or `keep` (real writing or a chemistry drawing).
/// Samples export as one versioned JSON document for tuning the EP-28
/// recogniser. Nothing here touches the network.

enum ScribbleLabel: String, Codable, CaseIterable, Equatable {
    case erase
    case keep
}

struct ScribblePoint: Codable, Equatable {
    var x: Double
    var y: Double
    /// Seconds since the first point of the stroke.
    var timeOffset: Double
    var force: Double
    /// Radians.
    var azimuth: Double
    /// Radians.
    var altitude: Double
    /// PencilKit's recorded point size (width), which its committed renderer
    /// draws from. Nil in exports made before the pen feel probe.
    var size: Double?
}

struct ScribbleStroke: Codable, Equatable {
    var points: [ScribblePoint]
}

extension ScribbleStroke {
    /// Raw points of a committed stroke. Timestamps become offsets from the
    /// stroke's first point so exports carry no wall-clock time.
    init(_ stroke: PKStroke) {
        let start = stroke.path.first?.timeOffset ?? 0
        points = stroke.path.map { point in
            ScribblePoint(
                x: Double(point.location.x), y: Double(point.location.y),
                timeOffset: point.timeOffset - start,
                force: Double(point.force),
                azimuth: Double(point.azimuth), altitude: Double(point.altitude),
                size: Double(point.size.width))
        }
    }
}

struct ScribbleSample: Codable, Equatable {
    var id: String
    var label: ScribbleLabel
    var strokes: [ScribbleStroke]

    init(id: String = UUID().uuidString, label: ScribbleLabel, strokes: [ScribbleStroke]) {
        self.id = id
        self.label = label
        self.strokes = strokes
    }

    /// Captures raw points from a drawing. Timestamps become offsets from each
    /// stroke's first point so exports carry no wall-clock time.
    init(id: String = UUID().uuidString, label: ScribbleLabel, drawing: PKDrawing) {
        self.init(id: id, label: label, strokes: drawing.strokes.map(ScribbleStroke.init))
    }
}

struct ScribbleSampleSet: Codable, Equatable {
    static let schema = "ember.scribble-samples/v1"

    var schema: String
    var samples: [ScribbleSample]

    init(samples: [ScribbleSample]) {
        self.schema = Self.schema
        self.samples = samples
    }
}

enum ScribbleSampleCodec {
    enum CodecError: Error, Equatable {
        case unsupportedSchema(String)
    }

    static let fileName = "scribble-samples.json"

    static func encode(_ set: ScribbleSampleSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(set)
    }

    static func decode(_ data: Data) throws -> ScribbleSampleSet {
        let set = try JSONDecoder().decode(ScribbleSampleSet.self, from: data)
        guard set.schema == ScribbleSampleSet.schema else { throw CodecError.unsupportedSchema(set.schema) }
        return set
    }

    /// Writes the export into a fresh temporary file for the Files share sheet.
    static func writeExport(_ set: ScribbleSampleSet, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try write(encode(set), named: fileName, in: directory)
    }

    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Pen feel probe

/// One line the captain wrote with the fountain pen at one of the toolbar's
/// widths, for calibrating `PenFeel` against PencilKit's real point sizes and
/// force-to-size response on the device.
struct PenFeelProbeLine: Codable, Equatable {
    var id: String
    /// The `PKInkingTool` width the line was written with, in points.
    var toolWidth: Double
    /// Index into the toolbar's pen widths (`Theme.penWidths`).
    var widthIndex: Int
    var inkType: String
    var strokes: [ScribbleStroke]

    init(id: String = UUID().uuidString, toolWidth: Double, widthIndex: Int, inkType: String, strokes: [ScribbleStroke]) {
        self.id = id
        self.toolWidth = toolWidth
        self.widthIndex = widthIndex
        self.inkType = inkType
        self.strokes = strokes
    }

    init(id: String = UUID().uuidString, widthIndex: Int, toolWidth: CGFloat, drawing: PKDrawing) {
        self.init(id: id, toolWidth: Double(toolWidth), widthIndex: widthIndex,
                  inkType: drawing.strokes.first?.ink.inkType.rawValue ?? PKInk.InkType.fountainPen.rawValue,
                  strokes: drawing.strokes.map(ScribbleStroke.init))
    }
}

struct PenFeelProbeSet: Codable, Equatable {
    static let schema = "ember.pen-feel-probe/v1"

    var schema: String
    var lines: [PenFeelProbeLine]

    init(lines: [PenFeelProbeLine]) {
        self.schema = Self.schema
        self.lines = lines
    }
}

enum PenFeelProbeCodec {
    static let fileName = "pen-feel-probe.json"

    static func encode(_ set: PenFeelProbeSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(set)
    }

    static func decode(_ data: Data) throws -> PenFeelProbeSet {
        let set = try JSONDecoder().decode(PenFeelProbeSet.self, from: data)
        guard set.schema == PenFeelProbeSet.schema else { throw ScribbleSampleCodec.CodecError.unsupportedSchema(set.schema) }
        return set
    }

    static func writeExport(_ set: PenFeelProbeSet, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try ScribbleSampleCodec.write(encode(set), named: fileName, in: directory)
    }
}
#endif
