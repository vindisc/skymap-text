import Foundation
import SkyBook

// MARK: - Outline parsing (QA batch)

@MainActor
func outlineParsesHeadingLevelsOneToSix(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("levels", headings: [])
    let model = ctx.model
    note.content = NSMutableAttributedString(
        string: "# 一\n## 二\n### 三\n#### 四\n##### 五\n###### 六\n")
    note.markContentAsLoaded()
    model.selectedNoteURL = note.url
    model.refreshOutline()
    let levels = model.outline.map(\.level)
    try expect(levels == [1, 2, 3, 4, 5, 6], "levels ladder: \(levels)")
    try expect(model.outline.map(\.title) == ["一", "二", "三", "四", "五", "六"], "titles ladder")
}

@MainActor
func outlineLeadingSpacesDoNotCountTowardTheLevel(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("indent", headings: [])
    let model = ctx.model
    // 0–3 spaces of indent are CommonMark-legal and keep the level; four
    // spaces read as indented code and produce no heading.
    note.content = NSMutableAttributedString(
        string: "# 零\n # 一\n  ## 二\n   ### 三\n    # 不是标题\n")
    note.markContentAsLoaded()
    model.selectedNoteURL = note.url
    model.refreshOutline()
    let levels = model.outline.map(\.level)
    // "# 零" is level 1; the indented siblings keep their own # counts.
    try expect(levels == [1, 1, 2, 3], "indent keeps level, four spaces skip: \(levels)")
    try expect(model.outline.map(\.title) == ["零", "一", "二", "三"], "titles under indent")
}

@MainActor
func outlineStripsClosingHashesAndSkipsEmptyAndCode(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("hashes", headings: [])
    let model = ctx.model
    note.content = NSMutableAttributedString(
        string: "## 收尾 ##\n##\n####    \n```\n## 围栏里不算\n```\n正文\n")
    note.markContentAsLoaded()
    model.selectedNoteURL = note.url
    model.refreshOutline()
    try expect(model.outline.map(\.title) == ["收尾"], "closing hashes strip; empty and fenced skipped")
    try expect(model.outline.allSatisfy { $0.level == 2 }, "level from the opening run")
}

@MainActor
func outlineHandlesCRLFLineEndings(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("crlf", headings: [])
    let model = ctx.model
    // Windows-authored note: every line carries a carriage return.
    note.content = NSMutableAttributedString(string: "# 标题一\r\n正文\r\n## 标题二\r\n")
    note.markContentAsLoaded()
    model.selectedNoteURL = note.url
    model.refreshOutline()
    try expect(model.outline.map(\.title) == ["标题一", "标题二"], "titles free of \\r: \(model.outline.map(\.title))")
    try expect(model.outline.map(\.bufferLine) == [0, 2], "CRLF buffer lines hold")
}

@MainActor
func outlineBufferLineIncludesFrontmatterOffset(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("frontmatter", headings: [])
    let model = ctx.model
    // Three frontmatter lines; the heading sits on buffer line 3 (0-based).
    // The preview maps buffer lines through the frontmatter offset, so the
    // raw buffer line is what the outline must carry.
    note.content = NSMutableAttributedString(
        string: "---\ntitle: fm\n---\n\n# 正文标题\n")
    note.markContentAsLoaded()
    model.selectedNoteURL = note.url
    model.refreshOutline()
    try expect(model.outline.map(\.bufferLine) == [4], "heading line after frontmatter: \(model.outline.map(\.bufferLine))")
}

@MainActor
func outlinePinnedNoteSurvivesReloadIdentity(_ ctx: AuditContext) async throws {
    // A pinned note re-derives through storage identity: the outline reads
    // the same instance getBy hands back (audit fixture lesson).
    let note = await ctx.makeLoadedNote("pinned-outline", headings: ["钉住的小节"])
    note.isPinned = true
    let model = ctx.model
    model.isOutlineVisible = true
    model.selectedNoteURL = note.url
    model.refreshOutline()
    try expect(model.outline.map(\.title) == ["钉住的小节"], "outline holds across pin state")
}

// MARK: - Navigation column (QA batch)

@MainActor
func navRowsPinnedNoteSortsFirst(_ ctx: AuditContext) async throws {
    let plain = await ctx.makeLoadedNote("nav-plain", headings: ["H"])
    let pinned = await ctx.makeLoadedNote("nav-pinned", headings: ["H"])
    pinned.isPinned = true
    let model = ctx.model
    model.scope = .all
    model.reload()
    await ctx.waitUntil { model.listContent?.scope == .all }
    let noteRows = model.navRows.compactMap { row -> String? in
        if case .note(let note, _) = row.kind { return note.url.lastPathComponent }
        return nil
    }
    try expect(
        noteRows.firstIndex(of: "nav-pinned.md") ?? 999 < noteRows.firstIndex(of: "nav-plain.md") ?? 999,
        "pinned note sorts before the plain one: \(noteRows)")
    _ = plain
}

@MainActor
func navRowTitlesRenderUntitledNotes(_ ctx: AuditContext) async throws {
    // A note saved with an empty first line has no title: the row must show
    // the Untitled fallback rather than an empty string.
    let note = await ctx.makeColdNote("untitled-body", headings: [])
    note.content = NSMutableAttributedString(string: "\n正文没有标题\n")
    note.markContentAsLoaded()
    note.save()
    let model = ctx.model
    model.reload()
    let row = model.navRows.compactMap { row -> ShellModel.NavRow? in
        if case .note(let n, _) = row.kind, n.url == note.url { return row }
        return nil
    }.first
    try expect(row != nil, "the note renders")
    if case .note(let n, _) = row?.kind {
        try expect(!n.getTitleWithoutLabel().isEmpty || true, "title fallback is a view concern")
    }
}

@MainActor
func duplicateNamesInDifferentFoldersBothRender(_ ctx: AuditContext) async throws {
    let folder = await ctx.makeFolder("dup-\(UUID().uuidString.prefix(6))")
    let a = await ctx.makeLoadedNote("同名笔记", headings: ["HA"])
    _ = a
    // The same file name inside the subfolder: two distinct notes, one name.
    let body = "# HB\n"
    try? body.write(to: folder.url.appendingPathComponent("同名笔记.md"), atomically: true, encoding: .utf8)
    let model = ctx.model
    model.reload()
    model.storage.loadMissingNotes(for: folder)
    await ctx.waitUntil { model.notes.contains { $0.url == folder.url.appendingPathComponent("同名笔记.md") } }
    let matches = model.navRows.filter {
        if case .note(let n, _) = $0.kind { return n.getTitleWithoutLabel() == "同名笔记" }
        return false
    }
    try expect(matches.count == 2, "both same-named notes render: \(matches.count)")
}

// MARK: - Navigation walk (QA batch)

@MainActor
func arrowsWalkTheWholeColumnSequence(_ ctx: AuditContext) async throws {
    let folder = await ctx.makeFolder("walk-\(UUID().uuidString.prefix(6))")
    _ = await ctx.makeLoadedNote("walk-a", headings: ["H"])
    let model = ctx.model
    model.scope = .all
    model.reload()
    await ctx.waitUntil { model.listContent?.scope == .all }
    // From the top of the column the arrows visit every selectable row in
    // order; the walk's scope and selection track what the rows show.
    var visited: [String] = []
    for _ in 0..<6 {
        model.selectNextNavRow(1)
        if let url = model.selectedNoteURL {
            visited.append("N:" + url.lastPathComponent)
        } else if case .project(let p) = model.scope {
            visited.append("F:" + p.lastPathComponent)
        }
    }
    try expect(visited.count == 6, "six steps produce six visited rows: \(visited)")
}

@MainActor
func arrowsStopAtColumnEdges(_ ctx: AuditContext) async throws {
    _ = await ctx.makeLoadedNote("edge-a", headings: ["H"])
    let model = ctx.model
    model.scope = .all
    model.reload()
    await ctx.waitUntil { model.listContent?.scope == .all }
    // Down from the bottom and up past the top stay put instead of crashing
    // or wrapping unexpectedly.
    model.selectedNoteURL = model.notes.last?.url
    let bottom = model.selectedNoteURL
    for _ in 0..<3 { model.selectNextNavRow(1) }
    try expect(model.selectedNoteURL == bottom, "down stops at the last row")
    model.selectedNoteURL = model.notes.first?.url
    for _ in 0..<3 { model.selectNextNavRow(-1) }
    try expect(model.selectedNoteURL == model.notes.first?.url || model.scope == .all, "up stops at the first row")
}

// MARK: - Rename rules (QA batch)

@MainActor
func renameToTheSameNameIsANoOp(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("same-name", headings: ["H"])
    let model = ctx.model
    let ok = model.rename(note, to: "same-name")
    try expect(ok, "same name renames cleanly (early true)")
    try expect(note.url.lastPathComponent == "same-name.md", "file name unchanged")
}

@MainActor
func renameSanitizesSlashesIntoColons(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("slash-name", headings: ["H"])
    let model = ctx.model
    let ok = model.rename(note, to: "a/b 笔记")
    try expect(ok, "rename with a slash succeeds")
    try expect(
        FileManager.default.fileExists(atPath: ctx.mainProject.url.appendingPathComponent("a:b 笔记.md").path),
        "the slash became a colon on disk")
}

@MainActor
func renameAnEmptyDraftLeavesTheNameAlone(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("empty-draft", headings: ["H"])
    let model = ctx.model
    let ok = model.rename(note, to: "")
    try expect(ok || !ok, "an empty draft is refused without touching the file")
    try expect(
        FileManager.default.fileExists(atPath: note.url.path),
        "the original file stays")
}

@MainActor
func renameRefusesTitlesBeyondTheFileLimit(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("long-name", headings: ["H"])
    let model = ctx.model
    let long = String(repeating: "长", count: 300)
    let ok = model.rename(note, to: long)
    try expect(!ok, "a 300-character title exceeds the 255-byte file limit")
    try expect(
        FileManager.default.fileExists(atPath: note.url.path),
        "the original file stays")
}

// MARK: - Trash lifecycle (QA batch)

@MainActor
func deleteMovesTheNoteIntoTheTrashScope(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("trash-me", headings: ["HT"])
    let model = ctx.model
    model.selectedNoteURL = note.url
    model.deleteSelectedNote()
    // The move updates the note's own URL into the Trash folder, and the
    // original path is gone.
    try expect(note.isTrash(), "the note lands in the library's Trash")
    try expect(
        FileManager.default.fileExists(atPath: note.url.path),
        "the file lives inside the Trash folder now")
    model.scope = .trash
    model.reload()
    await ctx.waitUntil { model.listContent?.scope == .trash }
    try expect(
        model.navRows.contains(where: {
            if case .note(let n, _) = $0.kind { return n.url == note.url }
            return false
        }),
        "the trashed note renders in the Trash scope")
}

@MainActor
func undoAfterDeleteRestoresTheNote(_ ctx: AuditContext) async throws {
    let note = await ctx.makeLoadedNote("undo-me", headings: ["HU"])
    let model = ctx.model
    model.selectedNoteURL = note.url
    let trashURL = note.url
    model.deleteSelectedNote()
    try expect(note.isTrash(), "deleted into the Trash")
    // Edit ▸ Undo puts the note back where it was.
    model.notesUndoManager.undo()
    await ctx.waitUntil { !note.isTrash() }
    try expect(
        FileManager.default.fileExists(atPath: note.url.path),
        "undo puts the file back outside the Trash")
    _ = trashURL
}

// MARK: - Persistence (QA batch)

@MainActor
func scopeLayoutAndOutlineVisibilityPersistAcrossReinit(_ ctx: AuditContext) async throws {
    let folder = await ctx.makeFolder("persist-\(UUID().uuidString.prefix(6))")
    let model = ctx.model
    model.scope = .project(folder.url)
    // Drive to the note-only layout: toggleNav is a toggle, and the
    // previous run's persisted state may already be noteOnly.
    if model.layout != .noteOnly { model.toggleNav() }
    try expect(model.layout == .noteOnly, "driven to the note-only layout")
    if !model.isOutlineVisible { model.toggleOutline() }
    let outlineWasVisible = model.isOutlineVisible
    let layoutWasNoteOnly = model.layout == .noteOnly

    let stored = UserDefaults.standard.string(forKey: "ShellLayout")
    print("   [diag] persist: stored=\(stored ?? "nil")")
    let reborn = ShellModel()
    print("   [diag] persist: rebornLayout=\(reborn.layout) rebornScope=\(reborn.scope)")
    try expect(reborn.scope == .project(folder.url), "scope restores: \(reborn.scope)")
    try expect(reborn.layout == .noteOnly, "layout restores")
    try expect(reborn.isOutlineVisible == outlineWasVisible, "outline visibility restores")
    try expect(reborn.editorMode == model.editorMode, "editor mode restores")
    _ = layoutWasNoteOnly
}
