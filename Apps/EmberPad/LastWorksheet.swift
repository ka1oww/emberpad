import Foundation
import EmberSyncKit

/// Remembers the worksheet left open when EmberPad last quit, so launch can reopen it.
///
/// Opening a Student worksheet records it; Back clears it. Quitting or being suspended with a
/// worksheet open leaves it recorded, so the next launch returns to that worksheet, as
/// GoodNotes restores its open document.
struct LastWorksheet {
    static let defaultsKey = "lastOpenWorksheet"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var storedID: UUID? {
        defaults.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
    }

    func opened(_ record: DocumentRecord) {
        // Teacher copies are never cards, so they are never what launch reopens.
        guard record.role == .student else { return }
        defaults.set(record.id.uuidString, forKey: Self.defaultsKey)
    }

    func closed(_ id: UUID) {
        guard storedID == id else { return }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// The worksheet launch should reopen: the stored one, if it is still a Student worksheet in the
    /// library and not archived.
    static func documentToReopen(storedID: UUID?, documents: [DocumentRecord]) -> UUID? {
        guard let storedID,
              let record = documents.first(where: { $0.id == storedID }),
              record.role == .student, !record.showsAsArchived else { return nil }
        return record.id
    }
}
