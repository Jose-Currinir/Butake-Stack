import Foundation
import Testing
@testable import ButakeStack

// New project, import, rename and commands: what the forms accept, as the engine does.

@Test func aNewProjectNameBecomesTheNameTheEngineAccepts() {
    #expect(NewProjectSheet.slug("Diseño web") == "diseno-web")
    #expect(NewProjectSheet.slug("Mi App_2") == "mi-app-2")
    #expect(NewProjectSheet.slug("  --Ñandú--  ") == "nandu")
    #expect(NewProjectSheet.slug("日本") == "")
    #expect(NewProjectSheet.slug("a.b/c") == "a-b-c")
}

@Test func theNewIdIsCheckedByBytesNotByCharacters() {
    #expect(ProjectRenameSheet.validId("web-2"))
    for wrong in ["b\u{0308}x", "5\u{0301}", "ab\u{0301}", String(repeating: "a", count: 41)] {
        #expect(!ProjectRenameSheet.validId(wrong), "\(wrong.unicodeScalars.map(\.value))")
    }
}

@Test func anImportedFolderGetsAFreeIdAndDomain() {
    let ids: Set<String> = ["gestion"]
    #expect(ImportFolderSheet.uniqueID("gestion", tld: "test", ids: ids, domains: ["gestion.test"]) == "gestion-2")
    #expect(ImportFolderSheet.uniqueID("gestion", tld: "test", ids: ids, domains: ["gestion.test", "gestion-2.test"]) == "gestion-3")
    // Another project serves the domain under a different id.
    #expect(ImportFolderSheet.uniqueID("tienda", tld: "test", ids: [], domains: ["tienda.test"]) == "tienda-2")
    // The same name under another suffix is free.
    #expect(ImportFolderSheet.uniqueID("tienda", tld: "local", ids: [], domains: ["tienda.test"]) == "tienda")
}

@Test func commandsKeepTheirQuotesAndAreNotRewrittenUnlessEdited() {
    #expect(ProjectProcess.words(of: "npm run \"test unit\"") == ["npm", "run", "test unit"])
    #expect(ProjectProcess.words(of: "a 'b c' d\\ e") == ["a", "b c", "d e"])
    #expect(ProjectProcess.words(of: "  ") == [])
    #expect(ProjectProcess.words(of: "x \"\"") == ["x", ""])
    #expect(ProjectProcess.words(of: "x \"sin cerrar y") == ["x", "sin cerrar y"])
    // What is shown is what is read back.
    let process = ProjectProcess(name: "check", program: "npm", args: ["run", "test unit", "--grep=\"a\"", ""], autostart: false)
    #expect(ProjectProcess.words(of: process.editableLine) == ["npm", "run", "test unit", "--grep=\"a\"", ""])
    #expect(ProjectProcess(name: "build", program: "cargo", args: ["build"], autostart: false).editableLine == "cargo build")
}
