import SwiftUI
import EmberSyncKit

/// One paper card in the library grid (design 5.1).
///
/// The thumbnail renders the Student copy's first page at A4 ratio. A Teacher
/// copy is never its own card: `hasTeacherCopy` only drives the Teacher badge.
/// Every colour routes through the EP-06 `Theme` tokens.
struct WorksheetCard: View {
    let record: DocumentRecord
    let thumbnail: UIImage?
    var hasTeacherCopy: Bool { record.pairedDocumentID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(Theme.cardTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(metaLine)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                badgeRow
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var thumbnailView: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(Color.white)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Placeholder while the first page renders: white paper with a quiet icon.
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.text3)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.width * 842 / 595)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.line, lineWidth: Theme.hairlineWidth)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 6)
            .accessibilityHidden(true)
        }
        .aspectRatio(595 / 842, contentMode: .fit)
    }

    private var metaLine: String {
        let day = Self.metaFormatter.string(from: record.importedAt)
        return "\(day) · \(record.pageCount) pages"
    }

    /// Always as tall as one badge, so cards without badges keep their titles level with
    /// their neighbours' (the grid centres cells of different heights).
    private var badgeRow: some View {
        ZStack(alignment: .leading) {
            badge("Ink", foreground: .clear, background: .clear, outline: nil)
                .hidden()
                .accessibilityHidden(true)
            badges
        }
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if record.status == .olderVersion {
                badge("Older version", foreground: Theme.text3, background: .clear, outline: Theme.text3)
            } else if record.isUpdated {
                badge("Updated", foreground: Theme.onAccent, background: Theme.accent, outline: nil)
            }
            if hasTeacherCopy {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("Teacher").font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.privateBg, in: Capsule())
                .foregroundStyle(Theme.privateBrand)
            }
            if record.hasInk {
                badge("Ink", foreground: Theme.text2, background: Theme.surface2, outline: nil)
            }
        }
    }

    private func badge(_ text: String, foreground: Color, background: Color, outline: Color?) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .overlay {
                if let outline {
                    Capsule().stroke(outline, lineWidth: Theme.hairlineWidth)
                }
            }
    }

    var accessibilityLabel: String {
        var parts = [record.title, metaLine]
        if record.status == .olderVersion {
            parts.append("Older version")
        } else if record.isUpdated {
            parts.append("Updated")
        }
        if hasTeacherCopy { parts.append("Teacher copy paired") }
        if record.hasInk { parts.append("Has ink") }
        return parts.joined(separator: ", ")
    }

    private static let metaFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_SG")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

#if DEBUG
#Preview("Worksheet card · badges") {
    let record = WorksheetCardPreviewSupport.updatedPairedInked
    WorksheetCard(record: record, thumbnail: nil)
        .padding(24)
        .background(Theme.bg)
}

#Preview("Worksheet card · older version") {
    let record = WorksheetCardPreviewSupport.olderVersion
    WorksheetCard(record: record, thumbnail: nil)
        .padding(24)
        .background(Theme.bg)
}

private enum WorksheetCardPreviewSupport {
    static func studentRecord(title: String, status: DocumentStatus, isUpdated: Bool,
                              hasInk: Bool, paired: Bool, classTag: String?) -> DocumentRecord {
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).pdf")
        let source = try! SourcePath(classFolder: "MI PU3", relativePath: title + ".pdf")
        let hash = try! ContentHash(rawValue: String(repeating: "a", count: 64))
        let paperKey = try! PaperKey(rawValue: "h2chem-paper-1")
        let publication = try! Publication(subject: "H2 Chemistry", classTag: classTag,
                                           paperKey: paperKey, role: .student, title: title)
        let entry = try! ManifestEntry(source: source, sha256: hash, size: 1024,
                                       modifiedAt: Date(), publication: publication)
        let record = DocumentRecord(source: entry, pageCount: 4, importedAt: Date(),
                                    hasInk: hasInk, status: status, title: title, isUpdated: isUpdated,
                                    pairedDocumentID: paired ? UUID() : nil)
        _ = url
        return record
    }

    static var updatedPairedInked: DocumentRecord {
        studentRecord(title: "Acids Tutorial", status: .current, isUpdated: true,
                      hasInk: true, paired: true, classTag: "MI PU3")
    }

    static var olderVersion: DocumentRecord {
        studentRecord(title: "Energetics Worksheet", status: .olderVersion, isUpdated: false,
                      hasInk: true, paired: false, classTag: nil)
    }
}
#endif
