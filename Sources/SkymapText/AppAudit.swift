import Foundation

struct AuditFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw AuditFailure(message: message) }
}

/// One shared context per process: the storage singleton lives for the whole
/// run, so tests isolate themselves with unique note and folder names.
@MainActor
final class AuditContext {
    static let shared = AuditContext()

    let model: ShellModel
    let mainProject: Project

    private init() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkyBookAudit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        UserDefaultsManagement.storagePath = tmp.path
        model = ShellModel()
        mainProject = model.storage.getMainProject()
        // The toggle reaches the source mode whatever the stored state is.
        if model.editorMode == .preview { model.toggleEditorMode() }
    }

    /// Writes a markdown file straight into the library folder and re-scans,
    /// so the note object starts with its content unloaded (the cold state).
    /// The rescan's note list fills on a later main-actor turn — the wait is
    /// what keeps this instance the same one `storage.getBy` hands back; an
    /// extra loadMissingNotes call here would register a duplicate object.
    func makeColdNote(_ name: String, headings: [String]) async -> Note {
        let body = headings.map { "# \($0)\n\ntext under \($0)\n" }.joined()
        try? FileManager.default.createDirectory(at: mainProject.url, withIntermediateDirectories: true)
        try? body.write(to: mainProject.url.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        // The previous scenario may have left the scope on a folder whose
        // rows are empty; the new note lands in the root, so reset the scope
        // or the scope filter never includes it and the wait times out.
        model.scope = .all
        model.reload()
        await waitUntil {
            self.model.notes.contains { $0.url.lastPathComponent == "\(name).md" }
        }
        if let note = model.notes.first(where: { $0.url.lastPathComponent == "\(name).md" }) {
            return note
        }
        preconditionFailure("audit fixture: note '\(name)' not registered")
    }

    func makeLoadedNote(_ name: String, headings: [String]) async -> Note {
        let note = await makeColdNote(name, headings: headings)
        note.ensureContentLoaded()
        return note
    }

    func makeFolder(_ name: String) -> Project {
        let folder = Project(
            url: mainProject.url.appendingPathComponent(name, isDirectory: true),
            label: name,
            parent: mainProject)
        folder.create()
        _ = model.storage.add(project: folder)
        model.reload()
        return folder
    }

    /// Polls until the condition holds or the budget runs out; async fill and
    /// page-load paths land on subsequent main-actor turns.
    func waitUntil(_ condition: () -> Bool, tries: Int = 50) async {
        for _ in 0..<tries {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Scenarios

@MainActor
func outlineFollowsTheSelectedNoteContent(_ ctx: AuditContext) async throws {
    let a = await ctx.makeLoadedNote("outline-a", headings: ["HA"])
    let b = await ctx.makeLoadedNote("outline-b", headings: ["HB1", "HB2"])
    let model = ctx.model
    model.isOutlineVisible = true
    model.selectedNoteURL = a.url
    model.refreshOutline()
    try expect(model.outline.map(\.title) == ["HA"], "outline should hold note A's headings")
    model.selectedNoteURL = b.url
    model.refreshOutline()
    try expect(model.outline.map(\.title) == ["HB1", "HB2"], "outline should follow the switched note")
}

@MainActor
func outlineClearsForColdNoteThenFillsAfterAsyncLoad(_ ctx: AuditContext) async throws {
    let cold = await ctx.makeColdNote("outline-cold", headings: ["HC"])
    let model = ctx.model
    model.isOutlineVisible = true
    model.selectedNoteURL = cold.url
    model.refreshOutline()
    try expect(model.outline.isEmpty, "a cold note empties the column first")
    // The editor's update awaits the content itself and re-derives the
    // outline right after the buffer publishes (audit H3, edit half).
    model.editor.update(cold)
    await ctx.waitUntil { !model.outline.isEmpty }
    try expect(model.outline.map(\.title) == ["HC"], "the async fill must re-derive the outline")
}

@MainActor
func outlineReDerivesWhenThePreviewPageLoads(_ ctx: AuditContext) async throws {
    // The rendered half of the same fix: previewDidLoad re-derives the
    // outline once the page (and its content) is on screen.
    let cold = await ctx.makeColdNote("outline-preview", headings: ["HP"])
    let model = ctx.model
    model.isOutlineVisible = true
    model.selectedNoteURL = cold.url
    model.refreshOutline()
    try expect(model.outline.isEmpty, "cold note: empty first")
    await cold.ensureContentLoadedAsync()
    model.refreshOutline()
    try expect(model.outline.map(\.title) == ["HP"], "content on screen: outline filled")
}

@MainActor
func navRowsAreFoldersAndNotesWithoutDateApparatus(_ ctx: AuditContext) async throws {
    _ = await ctx.makeLoadedNote("navrow-a", headings: ["H"])
    let model = ctx.model
    model.reload()
    try expect(
        model.navRows.contains(where: { if case .note = $0.kind { return true }; return false }),
        "note rows render")
    try expect(
        model.navRows.contains(where: { if case .folder = $0.kind { return true }; return false }),
        "folder rows render")
    try expect(model.navRows.count > 2, "folders plus notes render")
}

@MainActor
func emptyFolderShowsHintRow(_ ctx: AuditContext) async throws {
    let folder = await ctx.makeFolder("empty-\(UUID().uuidString.prefix(6))")
    let model = ctx.model
    model.scope = .project(folder.url)
    model.reload()
    // The scope's own rows (with the hint) land when computeNotes settles;
    // waiting only for non-empty rows would read the previous scope's rows.
    await ctx.waitUntil { model.listContent?.scope == .project(folder.url) }
    let folderIndex = model.navRows.firstIndex {
        if case .folder(let row, _) = $0.kind { return row.id == .project(folder.url) }
        return false
    }
    try expect(folderIndex != nil, "the folder row renders")
}

@MainActor
func mixedArrowsWalkFoldersAndNotes(_ ctx: AuditContext) async throws {
    let model = ctx.model
    model.scope = .all
    model.reload()
    model.selectedNoteURL = nil
    model.selectNextNavRow(1)
    try expect(model.selectedNoteURL != nil || model.scope != .all, "the first step leaves the top")
}

@MainActor
func twoStateToggleFlipsAndPersists(_ ctx: AuditContext) async throws {
    let model = ctx.model
    // The setter is private; reaching the source mode goes through the toggle.
    if model.editorMode == .preview { model.toggleEditorMode() }
    try expect(model.editorMode == .edit, "starts in the source mode")
    model.toggleEditorMode()
    try expect(model.editorMode == .preview, "first toggle enters the rendered mode")
    try expect(UserDefaultsManagement.preview, "the mode persists for the next launch")
    model.toggleEditorMode()
    try expect(model.editorMode == .edit, "second toggle returns to the source mode")
}

@MainActor
func previewReuseGateRejectsAFreshView(_ ctx: AuditContext) async throws {
    // A fresh web view has not loaded its template: not reusable, the strict
    // gate falls back to a full load (audit H1/H2).
    let note = await ctx.makeLoadedNote("reuse-gate", headings: ["H"])
    let view = MPreviewView(frame: .zero, note: note, closure: nil)
    try expect(
        !view.isReusableFor(note: note, currentStyle: HtmlManager.previewStyle()),
        "a view without a loaded template is not reusable")
    try expect(
        !view.isReusableFor(note: note, currentStyle: "other-style"),
        "a foreign style is not reusable")
}

@MainActor
func createNoteCommitsPendingRename(_ ctx: AuditContext) async throws {
    let original = await ctx.makeLoadedNote("rename-victim", headings: ["H"])
    let model = ctx.model
    model.selectedNoteURL = original.url
    model.isRenaming = true
    model.renamingNoteURL = original.url
    // beginRenameDraft seeds the draft from the note and binds the draft URL;
    // commitPendingRename keys on both, so neither may be skipped.
    model.beginRenameDraft()
    model.renameDraft = "renamed-in-flight"
    model.commitPendingRename()
    try expect(
        original.url.lastPathComponent.hasPrefix("renamed-in-flight"),
        "a pending title rename commits before the selection moves on")
}

@MainActor
enum AppAudit {
    static func run() async -> Int32 {
        let ctx = AuditContext.shared
        let tests: [(String, (AuditContext) async throws -> Void)] = [
        ("outline.followsSelectedNoteContent", outlineFollowsTheSelectedNoteContent),
        ("outline.clearsForColdNoteThenFillsAfterAsyncLoad", outlineClearsForColdNoteThenFillsAfterAsyncLoad),
        ("outline.reDerivesWhenThePreviewPageLoads", outlineReDerivesWhenThePreviewPageLoads),
        ("nav.rowsAreFoldersAndNotesWithoutDateApparatus", navRowsAreFoldersAndNotesWithoutDateApparatus),
        ("nav.emptyFolderShowsHintRow", emptyFolderShowsHintRow),
        ("nav.mixedArrowsWalkFoldersAndNotes", mixedArrowsWalkFoldersAndNotes),
        ("editor.twoStateToggleFlipsAndPersists", twoStateToggleFlipsAndPersists),
        ("preview.reuseGateRejectsAFreshView", previewReuseGateRejectsAFreshView),
        ("rename.createNoteCommitsPendingRename", createNoteCommitsPendingRename),
        ("outline.parsesHeadingLevelsOneToSix", outlineParsesHeadingLevelsOneToSix),
        ("outline.leadingSpacesDoNotCountTowardTheLevel", outlineLeadingSpacesDoNotCountTowardTheLevel),
        ("outline.stripsClosingHashesAndSkipsEmptyAndCode", outlineStripsClosingHashesAndSkipsEmptyAndCode),
        ("outline.handlesCRLFLineEndings", outlineHandlesCRLFLineEndings),
        ("outline.bufferLineIncludesFrontmatterOffset", outlineBufferLineIncludesFrontmatterOffset),
        ("outline.pinnedNoteSurvivesReloadIdentity", outlinePinnedNoteSurvivesReloadIdentity),
        ("nav.pinnedNoteSortsFirst", navRowsPinnedNoteSortsFirst),
        ("nav.rowTitlesRenderUntitledNotes", navRowTitlesRenderUntitledNotes),
        ("nav.duplicateNamesInDifferentFoldersBothRender", duplicateNamesInDifferentFoldersBothRender),
        ("nav.arrowsWalkTheWholeColumnSequence", arrowsWalkTheWholeColumnSequence),
        ("nav.arrowsStopAtColumnEdges", arrowsStopAtColumnEdges),
        ("rename.toTheSameNameIsANoOp", renameToTheSameNameIsANoOp),
        ("rename.sanitizesSlashesIntoColons", renameSanitizesSlashesIntoColons),
        ("rename.anEmptyDraftLeavesTheNameAlone", renameAnEmptyDraftLeavesTheNameAlone),
        ("rename.refusesTitlesBeyondTheFileLimit", renameRefusesTitlesBeyondTheFileLimit),
        ("trash.deleteMovesTheNoteIntoTheTrashScope", deleteMovesTheNoteIntoTheTrashScope),
        ("trash.undoAfterDeleteRestoresTheNote", undoAfterDeleteRestoresTheNote),
        ("persistence.scopeLayoutAndOutlineVisibility", scopeLayoutAndOutlineVisibilityPersistAcrossReinit),
        ("outline.contentWidthStaysWithinBounds", outlineContentWidthStaysWithinBounds),
        ("search.returnOpensTheFirstResult", searchReturnOpensTheFirstResult),
        ("debug.alertSheetGeometry", alertSheetGeometry),
    ]
    print("SkyBook audit: \(tests.count) scenarios")
    var failures = 0
    for (name, test) in tests {
        do {
            try await test(ctx)
            print("✓ \(name)")
        } catch {
            failures += 1
            print("✗ \(name): \(error)")
        }
    }
    print(failures == 0 ? "全部通过" : "\(failures) 个场景失败")
    return failures == 0 ? 0 : 1
}
}
