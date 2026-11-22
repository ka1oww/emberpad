import ObjectiveC
import PencilKit

/// EP166: keeps PencilKit's replica record from holding back the live ink.
///
/// PencilKit keeps a record of every drawing given strokes (`PKDrawing(strokes:)`, or a drawing a canvas is given),
/// one entry each, and it only grows while the app runs: the live pen alone adds about seven entries a stroke. Each
/// time a drawing is serialized (`dataRepresentation()`, which the autosave and Present both call), PencilKit arms a
/// save of that record 2.5 s later, and the save rewrites the whole record to the app's preferences on PencilKit's
/// one record queue. Every drawing made while it runs waits for it, the live pen's included. On a long-running app
/// the record holds hundreds of thousands of entries and the save takes a second or more, so a stroke begun about
/// 3.5 s after a pause (the 1 s autosave, then the 2.5 s) shows no ink until the save ends.
///
/// The saved record is not read back usefully: PencilKit sets a "dirty" token on the first serialize and, finding it
/// at the next launch, resets the record (its own recovery for an app that ended before saving). So this stops only
/// the save: PencilKit's private `_scheduleSaveState` is replaced with one that does nothing. The record in memory,
/// the dirty token and every saved ink file are as before. If a later PencilKit lacks that method, or it takes other
/// arguments, nothing is changed and PencilKit behaves as it always has.
enum PencilKitRecord {
    private static let className = "PKReplicaManager"
    private static let saveName = "_scheduleSaveState"
    /// A method taking no arguments and returning nothing.
    private static let saveTypes = "v16@0:8"

    /// Whether PencilKit's record saves are held off in this process.
    @MainActor private(set) static var savesHeldOff = false

    /// Holds off PencilKit's record saves for the rest of the run. Call once at launch, before any ink.
    @MainActor static func holdOffSaves() {
        guard !savesHeldOff, let manager = NSClassFromString(className) else { return }
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(manager, &count) else { return }
        defer { free(methods) }
        let selector = NSSelectorFromString(saveName)
        // Only the class's own method, so nothing inherited is ever replaced.
        guard let save = (0..<Int(count)).map({ methods[$0] }).first(where: { method_getName($0) == selector }),
              let types = method_getTypeEncoding(save), String(cString: types) == saveTypes else { return }
        let skip: @convention(block) (AnyObject) -> Void = { _ in }
        method_setImplementation(save, imp_implementationWithBlock(skip))
        savesHeldOff = true
    }
}
