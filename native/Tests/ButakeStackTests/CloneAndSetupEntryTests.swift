import Foundation
import Testing
@testable import ButakeStack

/// «Clonar repositorio…» is in ⌘K whatever tools are on, and runs the shared clone sheet.
@MainActor @Test func thePaletteOffersCloningARepository() throws {
    let store = StackStore.shared
    let saved = store.showClone
    defer { store.showClone = saved }
    store.showClone = false
    let command = try #require(CommandPalette(store: store).commands.first { $0.id == "clone" })
    #expect(command.title == L("menu.cloneRepository"))
    command.run()
    #expect(store.showClone)
}

/// «Marcar lo habitual» only marks profiles that exist, and the assistant's work step keeps them.
@Test func theUsualProfilesExist() {
    let ids = Set(WorkProfile.all.map(\.id))
    #expect(!WorkStep.usual.isEmpty && WorkStep.usual.isSubset(of: ids))
}
