import Foundation
import Testing
@testable import EmberSyncKit

/// EP69: the library's folders come from each copy's source path. Every name below is synthetic.
struct LibraryFoldersTests {
    /// A delivered Drive copy: `path` is below the subject folder, and the title carries the folders as context, as
    /// `EmberLibrarySource` writes it.
    static func driveRecord(_ subject: String, _ path: String, hasInk: Bool = false) throws -> DocumentRecord {
        let components = path.split(separator: "/").map(String.init)
        let stem = String(components.last!.dropLast(4))
        let title = (components.dropLast().filter { !$0.hasPrefix("_") } + [stem]).joined(separator: " / ")
        let publication = try Publication(subject: subject, paperKey: PaperKey(rawValue: subject + "/" + path),
                                          role: .student, title: title)
        let entry = try ManifestEntry(source: SourcePath(classFolder: subject, relativePath: path),
                                      sha256: .digest(Data(path.utf8)), size: 1, modifiedAt: fixtureDate, publication: publication)
        return DocumentRecord(source: entry, pageCount: 1, importedAt: fixtureDate, hasInk: hasInk)
    }

    /// A worksheet imported from Files (or a loose Inbox PDF): no publication record, its class folder is its subject.
    static func importedRecord(_ classFolder: String, _ path: String) throws -> DocumentRecord {
        let entry = try ManifestEntry(source: SourcePath(classFolder: classFolder, relativePath: path),
                                      sha256: .digest(Data((classFolder + path).utf8)), size: 1, modifiedAt: fixtureDate)
        return DocumentRecord(source: entry, pageCount: 1, importedAt: fixtureDate)
    }

    func chemistry() throws -> [DocumentRecord] {
        try [
            Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/EMBER - Alkanes.pdf"),
            Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Tutorial/Alkanes Tutorial.pdf"),
            Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Tutorial/Alkanes Tutorial Part 2.pdf"),
            Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Arenes/EMBER - Arenes.pdf"),
            Self.driveRecord("Chemistry", "Answering Technique/EMBER - Answering Techniques.pdf"),
            Self.driveRecord("Chemistry", "Organic Memory Sheets/Synthetic Memory Sheet.pdf"),
            Self.driveRecord("Chemistry", "TYS PAPERS/Paper 10.pdf"),
            Self.driveRecord("Chemistry", "TYS PAPERS/Paper 2.pdf"),
            Self.driveRecord("Chemistry", "Synthetic Loose Sheet.pdf"),
        ]
    }

    @Test func aSubjectShowsItsTopFoldersInNameOrderAndItsLooseWorksheets() throws {
        let records = try chemistry()
        let top = LibraryFolders.contents(of: records, subject: "Chemistry", at: [])
        #expect(top.folders.map(\.name) == ["Answering Technique", "NOTES & TUTORIALS", "Organic Memory Sheets", "TYS PAPERS"])
        #expect(top.folders.map(\.itemCount) == [1, 2, 1, 2])
        #expect(top.folders.allSatisfy { $0.subject == "Chemistry" && $0.path == [$0.name] })
        #expect(top.worksheets.map { LibraryFolders.ownTitle(of: $0) } == ["Synthetic Loose Sheet"])
    }

    @Test func aTopicShowsItsNotesAndItsNestedTutorialFolder() throws {
        let records = try chemistry()
        let alkanes = LibraryFolders.contents(of: records, subject: "Chemistry", at: ["NOTES & TUTORIALS", "Alkanes"])
        #expect(alkanes.folders == [LibraryFolderItem(subject: "Chemistry", path: ["NOTES & TUTORIALS", "Alkanes", "Tutorial"],
                                                      itemCount: 2)])
        #expect(alkanes.worksheets.map { LibraryFolders.ownTitle(of: $0) } == ["EMBER - Alkanes"])
        let tutorial = LibraryFolders.contents(of: records, subject: "Chemistry", at: ["NOTES & TUTORIALS", "Alkanes", "Tutorial"])
        #expect(tutorial.folders.isEmpty)
        #expect(Set(tutorial.worksheets.map { LibraryFolders.ownTitle(of: $0) }) == ["Alkanes Tutorial", "Alkanes Tutorial Part 2"])
        // Everything at or below a folder, for search.
        #expect(LibraryFolders.documents(records, under: ["NOTES & TUTORIALS", "Alkanes"]).count == 3)
        #expect(LibraryFolders.documents(records, under: ["NOTES & TUTORIALS"]).count == 4)
        #expect(LibraryFolders.documents(records, under: []).count == records.count)
        #expect(LibraryFolders.documents(records, under: ["NOTES & TUTORIALS", "Alk"]).isEmpty, "a name prefix is not a folder")
    }

    @Test func driveNameOrderIsCaseInsensitiveAndNumeric() {
        #expect(["Paper 10", "paper 2", "Answering", "PRACTICAL"].sorted(by: LibraryFolders.nameOrder)
                == ["Answering", "paper 2", "Paper 10", "PRACTICAL"])
    }

    @Test func ownTitleDropsTheFolderContextAndKeepsAnUpdatedStamp() throws {
        var record = try Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Tutorial/Alkanes Tutorial.pdf")
        #expect(record.title == "NOTES & TUTORIALS / Alkanes / Tutorial / Alkanes Tutorial")
        #expect(LibraryFolders.ownTitle(of: record) == "Alkanes Tutorial")
        record.title = "NOTES & TUTORIALS / Alkanes / Tutorial / Alkanes Tutorial (updated 12 Nov)"
        #expect(LibraryFolders.ownTitle(of: record) == "Alkanes Tutorial (updated 12 Nov)")
        // An underscore folder is in the path but not the title.
        let archived = try Self.driveRecord("Math", "_legacy-archive/Old Workspace/Old Paper.pdf")
        #expect(archived.title == "Old Workspace / Old Paper")
        #expect(LibraryFolders.ownTitle(of: archived) == "Old Paper")
        // A title that does not start with its folders is shown as it is.
        record.title = "Something else"
        #expect(LibraryFolders.ownTitle(of: record) == "Something else")
    }

    @Test func worksheetsImportedFromFilesSitAtTheirClassFolderTopLevel() throws {
        let imported = try Self.importedRecord("Synthetic Class", "worksheet.pdf")
        let nested = try Self.importedRecord("Synthetic Class", "Unit 1/worksheet 2.pdf")
        #expect(imported.subject == "Synthetic Class")
        let top = LibraryFolders.contents(of: [imported, nested], subject: "Synthetic Class", at: [])
        #expect(top.worksheets.map(\.id) == [imported.id])
        #expect(top.folders.map(\.name) == ["Unit 1"])
        #expect(LibraryFolders.ownTitle(of: imported) == "worksheet.pdf", "a version-1 title is its file name, as before")
    }

    @Test func sourceFoldersAreRecognisedButTextSourcesIsNot() throws {
        for name in ["Source (LaTeX)", "Notes Source (LaTeX)", "Word Source", "word source", "Source", "SOURCE"] {
            #expect(LibraryFolders.isHiddenSourceFolder(name), "\(name)")
        }
        for name in ["Text Sources", "Sources", "source-pages", "Synthetic Source Notes", "NOTES & TUTORIALS", "Tutorial"] {
            #expect(!LibraryFolders.isHiddenSourceFolder(name), "\(name)")
        }
        let build = try Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Notes Source (LaTeX)/ALKANES/EMBER - ALKANES.pdf")
        let word = try Self.driveRecord("Chemistry", "NOTES & TUTORIALS/Alkanes/Tutorial/Word Source/Alkanes Tutorial.pdf")
        let text = try Self.driveRecord("Chemistry", "Text Sources/Synthetic Text.pdf")
        #expect(LibraryFolders.isUnderHiddenSourceFolder(build.source))
        #expect(LibraryFolders.isUnderHiddenSourceFolder(word.source))
        #expect(!LibraryFolders.isUnderHiddenSourceFolder(text.source))
    }

    @Test func aSubjectAtTheAllSubjectsLevelCountsItsTopItems() throws {
        let item = LibraryFolders.subjectItem("Chemistry", documents: try chemistry())
        #expect(item.path.isEmpty && item.name == "Chemistry")
        #expect(item.itemCount == 5, "four folders and one loose worksheet")
    }
}
