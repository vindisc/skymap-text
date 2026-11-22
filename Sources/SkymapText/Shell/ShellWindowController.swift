import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// Hosts the SwiftUI shell in a window of its own. This is the app's default
/// and only window on branch `spm`; the storyboard window stays dormant behind
/// `defaults write local.skybook MiaoYanShell -bool NO`.
@available(macOS 14, *)
final class ShellWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private var appearanceObservation: NSKeyValueObservation?
    static var isRequested: Bool {
        // SwiftPM build: the shell is the only window; `-MiaoYanShell NO`
        // still opts out explicitly.
        UserDefaults.standard.object(forKey: "MiaoYanShell") != nil
            ? UserDefaults.standard.bool(forKey: "MiaoYanShell")
            : true
    }

    let model: ShellModel

    init() {
        model = ShellModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The bundle's display name, for the Window menu, Mission Control
        // and VoiceOver; the title bar still draws none.
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? "SkyBook"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The storyboard window's minimum (AppDelegate.normalizeMainWindowFrame).
        window.minSize = NSSize(width: 960, height: 600)
        window.backgroundColor = ShellPalette.background
        window.isReleasedWhenClosed = false
        // An empty unified toolbar gives the title bar Notes' 52pt height and
        // centres the traffic lights in it; the columns draw their own
        // controls on that line.
        window.toolbar = NSToolbar(identifier: "MiaoYanShellToolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        super.init(window: window)

        window.contentViewController = ShellSplitViewController(model: model)
        // The panes have no preferred size, so assigning the controller
        // shrinks the window to its minimum; restore the default first.
        window.setContentSize(NSSize(width: 1100, height: 700))
        // Launch focus lands in the editor, not whatever SwiftUI control
        // happens to lead the key-view loop.
        window.initialFirstResponder = model.editor.textView
        window.delegate = self
        // A live light/dark switch, from the system or from Settings, has to
        // reach the editor's highlight colours and the preview's CSS too; the
        // storyboard window does this from MainWindowController.
        appearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.appearanceDidChange() }
        }
        // First shell launch: take the storyboard window's frame, so switching
        // windows does not move or resize MiaoYan.
        if !window.setFrameUsingName("MiaoYanShellWindow"), !window.setFrameUsingName("myMainWindow") {
            window.center()
        }
        // A first launch opens centred at the preferred size, as
        // AppDelegate.normalizeMainWindowFrame does for the storyboard window,
        // whose ViewController then clears the flag.
        Self.recentreIfLost(window, force: UserDefaultsManagement.isFirstLaunch)
        UserDefaultsManagement.isFirstLaunch = false
        window.setFrameAutosaveName("MiaoYanShellWindow")
        applyWindowLevel()
        windowLevelObserver = NotificationCenter.default.addObserver(
            forName: .alwaysOnTopChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyWindowLevel() }
        }
        KeyboardShortcuts.onKeyUp(for: .activateWindow) { [weak self] in
            self?.toggleFrontmost()
        }
        observePresentation()
        observeOpenNote()
        retargetMainMenu()
        model.onFoldersChanged = { [weak self] in self?.fsManager?.restart() }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .editorSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.applyEditorSettings() }
        }
        fontSetObserver = NotificationCenter.default.addObserver(
            forName: NSFont.fontSetChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.installedFontsDidChange() }
        }
        fsManager = FileSystemEventManager(storage: AppEnvironment.current.storage, delegate: self)
        fsManager?.start()
        model.editor.onWillSave = { [weak self] in self?.blockFSUpdates() }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyUp(event)
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }
        menuClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleMenuClick(event)
        }
        // Quitting mid-presentation must not leave preview as the stored
        // mode, or the next launch opens in preview.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.setPresenting(false) }
        }
    }

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var scrollMonitor: Any?
    private var menuClickMonitor: Any?
    private var terminateObserver: NSObjectProtocol?

    /// The storyboard window's launch guard: a saved frame that is off every
    /// screen or smaller than the layout needs, or any frame when `force`,
    /// comes back centred at the preferred size.
    private static func recentreIfLost(_ window: NSWindow, force: Bool) {
        let saved = window.frame
        let isOffScreen = NSScreen.screens.allSatisfy { !$0.visibleFrame.intersects(saved) }
        // Only a frame the window cannot legally hold is "too small"; the
        // layout's 1100×680 comfort size is not a floor, or a deliberate
        // 1000×640 window came back enlarged on every launch.
        let isTooSmall = saved.width < window.minSize.width || saved.height < window.minSize.height
        guard force || isOffScreen || isTooSmall,
            let visible = (isOffScreen ? nil : window.screen)?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return }
        let size = NSSize(
            width: min(1280, max(900, visible.width - 40)),
            height: min(760, max(620, visible.height - 40)))
        window.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
            display: true)
    }

    // The storyboard window's column adoption was retired with the merged
    // navigation column; the SwiftPM build starts from its own defaults.

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Menu commands

    /// The storyboard menu sends many commands to stand-in `ViewController`
    /// and `EditTextView` objects that forward to the storyboard window, which
    /// the shell does not have. Pointing those items at the first responder
    /// lets the real editor take its formatting commands and this controller
    /// take the rest; items nobody answers are disabled by AppKit.
    private func retargetMainMenu() {
        // Folder items go to the storyboard sidebar's stand-ins and share
        // selectors with note items (`renameMenu:`), so they get folder
        // actions of their own here.
        let folderActions: [Selector: Selector] = [
            NSSelectorFromString("renameMenu:"): #selector(renameFolderMenu(_:)),
            NSSelectorFromString("revealInFinder:"): #selector(revealFolderMenu(_:)),
            NSSelectorFromString("deleteMenu:"): #selector(deleteFolderMenu(_:)),
            NSSelectorFromString("add:"): #selector(newFolderMenu(_:)),
            NSSelectorFromString("addProject:"): #selector(newFolderMenu(_:)),
            NSSelectorFromString("newSubfolder:"): #selector(newFolderMenu(_:)),
        ]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.target is SidebarProjectView || item.target is SidebarCellView,
                    let action = item.action, let folderAction = folderActions[action]
                {
                    item.target = self
                    item.action = folderAction
                } else if item.target is ViewController || item.target is EditTextView {
                    item.target = nil
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
    }

    // MARK: Open and import

    /// File ▸ Open: one file or folder on its own, until Command-Shift-W.
    @IBAction func singleOpen(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.urls.first else { return }
            self?.model.openSingle(url, siblingFiles: AppDelegate.siblingNoteFiles(of: url))
        }
    }

    /// File ▸ Import: Markdown files, or every note inside picked folders,
    /// copied into the main folder.
    @IBAction func importFiles(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.message = I18n.str("Select Markdown files or folders to import")
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK else { return }
            let picked = panel.urls
            let extensions = AppEnvironment.current.storage.allowedExtensions
            // A picked folder can be huge; scan it off the main thread. Only the
            // scan leaves it, so self never crosses into the detached task.
            Task { @MainActor [weak self] in
                let files = await Task.detached(priority: .userInitiated) {
                    ViewController.collectImportableFiles(from: picked, allowedExtensions: extensions)
                }.value
                guard let self else { return }
                guard !files.isEmpty else {
                    self.model.host?.toast(message: I18n.str("No Markdown files to import"), style: .failure)
                    return
                }
                self.model.importNotes(files)
            }
        }
    }

    // MARK: Folders

    @IBAction func newFolderMenu(_ sender: Any?) { model.promptNewFolder() }

    /// The name is edited in its row, so the folders must be showing, as the
    /// storyboard sidebar needs a visible row to edit.
    @IBAction func renameFolderMenu(_ sender: Any?) {
        guard model.layout == .all else { return }
        model.renamingFolderURL = model.selectedFolder?.url
    }

    @IBAction func revealFolderMenu(_ sender: Any?) {
        guard let url = sidebarFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @IBAction func deleteFolderMenu(_ sender: Any?) {
        guard let folder = model.selectedFolder else { return }
        model.confirmDeleteFolder(folder)
    }

    /// File ▸ Move: the storyboard's Move submenu at the open note's row, the
    /// Trash first and then the library and every folder, indented as the
    /// sidebar nests them.
    @IBAction func moveMenu(_ sender: Any?) {
        guard let note = model.selectedNote else { return }
        let menu = NSMenu()
        if !note.isTrash() {
            let trash = NSMenuItem(title: I18n.str("Trash"), action: #selector(deleteNote(_:)), keyEquivalent: "")
            trash.target = self
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(trash)
            menu.addItem(.separator())
        }
        menu.autoenablesItems = false
        let destinations = Sidebar().moveDestinations()
        for item in MoveMenuFiller.items(
            for: model.selectedNotes, destinations: destinations, target: self, action: #selector(moveToFolder(_:)))
        {
            menu.addItem(item)
        }
        popUpAtSelectedRow(menu)
    }

    @objc private func moveToFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Project else { return }
        model.move(model.selectedNotes, to: folder)
    }

    @IBAction func toggleSidebarPanel(_ sender: Any?) { model.toggleNav() }
    @IBAction func toggleNoteList(_ sender: Any?) { model.toggleNav() }
    @IBAction func togglePreview(_ sender: Any?) { model.toggleEditorMode() }
    /// ⌘E: the minimal source ↔ rendered toggle.
    @IBAction func toggleEditorMode(_ sender: Any?) { model.toggleEditorMode() }
    /// ⌘5: the outline column on or off.
    @IBAction func toggleOutlinePanel(_ sender: Any?) { model.toggleOutline() }
    @IBAction func togglePresentation(_ sender: Any?) { model.setPresenting(!model.isPresenting) }
    @IBAction func toggleMagicPPT(_ sender: Any?) { model.setPresenting(!model.isPresenting, ppt: true) }
    @IBAction func toggleTOC(_ sender: Any?) { model.preview?.toggleTOC() }
    @IBAction func formatText(_ sender: Any?) { model.format() }
    @IBAction func cleanTypography(_ sender: Any?) { model.cleanTypography() }
    @IBAction func fileMenuNewNote(_ sender: Any?) { model.createNote() }
    /// Command-Delete deletes notes only from the list, as in the storyboard
    /// window: never while typing, searching or presenting.
    @IBAction func deleteNote(_ sender: Any?) {
        guard !isTypingOrFinding, !model.isPresenting else { return }
        model.deleteSelectedNote()
    }

    /// Text has the keyboard (the editor, the title, the search field, a
    /// folder name) or a find bar is open.
    private var isTypingOrFinding: Bool {
        window?.firstResponder is NSTextView || model.editor.textView.isSearchBarVisible
            || model.preview?.isSearchBarVisible == true
    }
    @IBAction func renameMenu(_ sender: Any?) { model.isRenaming = model.selectedNote != nil }
    /// ⌘K: the search palette. Also carries the old ⌘/ route so the muscle
    /// memory from the list-filter days keeps working.
    @IBAction func searchNotes(_ sender: Any?) {
        model.openPalette()
    }

    @IBAction func pinMenu(_ sender: Any?) {
        guard let note = model.selectedNote else { return }
        model.togglePin(note)
    }

    /// Option-Command-R: the folder while the sidebar has focus, as the
    /// storyboard's finderMenu decides, otherwise every selected note.
    @IBAction func finderMenu(_ sender: Any?) {
        if column(of: window?.firstResponder) == .nav {
            guard let url = sidebarFolderURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        model.revealInFinder(model.selectedNotes)
    }

    /// The chosen folder, or the Trash folder while the Trash is shown.
    private var sidebarFolderURL: URL? {
        if model.scope == .trash { return AppEnvironment.current.storage.getDefaultTrash()?.url }
        return model.selectedFolder?.url
    }

    /// Find, find and replace, next and previous, by the storyboard window's
    /// rules: the preview's own search while the preview is showing, the
    /// editor's find bar otherwise. Replace needs the editor, since the
    /// preview's buffer may belong to another note in the shell.
    @IBAction func textFinder(_ sender: NSMenuItem) {
        let editor = model.editor.textView
        if model.editorMode == .preview || model.isPresenting {
            guard let preview = model.preview else { return }
            if sender.tag == NSFindPanelAction.next.rawValue {
                preview.findNext()
            } else if sender.tag == NSFindPanelAction.previous.rawValue {
                preview.findPrevious()
            } else {
                preview.showSearchBar(mode: .find)
            }
            return
        }
        if let action = NSFindPanelAction(rawValue: UInt(sender.tag)) {
            switch action {
            case .next, .previous:
                if !editor.isSearchBarVisible {
                    editor.showSearchBar(prefilledText: editor.currentSearchQuery)
                }
                action == .next ? editor.findNext() : editor.findPrevious()
                return
            case .setFindString:
                editor.useSelectionForFind()
                return
            default:
                break
            }
        }
        if let action = NSTextFinder.Action(rawValue: sender.tag) {
            switch action {
            case .showFindInterface:
                editor.showSearchBar(prefilledText: nil, mode: .find)
                return
            case .showReplaceInterface:
                editor.showSearchBar(prefilledText: nil, mode: .replace)
                return
            case .hideFindInterface:
                editor.hideSearchBar()
                return
            default:
                break
            }
        }
        editor.performTextFinderAction(sender)
    }

    @IBAction func showVersionHistory(_ sender: Any?) { model.showVersionHistory() }

    /// Words, dates and backlinks, under the note's title.
    @IBAction func showInfo(_ sender: Any?) {
        guard let note = model.selectedNote,
            let split = window?.contentViewController as? NSSplitViewController,
            let detail = split.splitViewItems.last?.viewController.view
        else { return }
        let content = ContentViewController()
        content.note = note
        infoPopover.contentViewController = content
        // The hosting view is flipped: this is the title line at the top.
        let anchor = NSRect(x: ShellStyle.noteTextInset, y: 0, width: 1, height: ShellStyle.headerHeight - 10)
        infoPopover.show(relativeTo: anchor, of: detail, preferredEdge: .maxY)
    }

    private lazy var infoPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .semitransient
        return popover
    }()

    /// The chosen folder, or the library, in the preferred terminal; in
    /// single-file mode the folder holding the open file, which the
    /// storyboard window selects in its sidebar there.
    @IBAction func openInTerminal(_ sender: Any?) {
        guard let url = terminalURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", ViewController.preferredTerminalBundleID(), url.path]
        do {
            try process.run()
        } catch {
            AppDelegate.trackError(error, context: "ShellWindowController.openInTerminal")
        }
    }

    /// The Trash opens the library, as in the storyboard window.
    private var terminalURL: URL? {
        if model.isSingleMode, let url = UserDefaultsManagement.singleModeURL {
            if FileManager.default.directoryExists(atUrl: url) { return url }
            return AppEnvironment.current.storage.getProjectBy(url: url)?.url ?? url.deletingLastPathComponent()
        }
        // The library loaded at launch: a folder changed in Settings is only
        // used after the restart.
        return model.selectedFolder?.url ?? AppEnvironment.current.storage.getDefault()?.url ?? UserDefaultsManagement.storageUrl
    }

    @IBAction func cleanUnusedAttachments(_ sender: Any?) { model.cleanUnusedAttachments() }
    @IBAction func exportMiaoYanPPT(_ sender: Any?) { model.export(.ppt) }
    @IBAction func zoomInFontSize(_ sender: Any?) { model.adjustFontSize(by: 1) }
    @IBAction func zoomOutFontSize(_ sender: Any?) { model.adjustFontSize(by: -1) }
    @IBAction func resetFontSize(_ sender: Any?) { model.adjustFontSize(by: nil) }
    @IBAction func duplicate(_ sender: Any?) { model.duplicate(model.selectedNotes) }
    @IBAction func reloadCurrentNote(_ sender: Any?) { model.reloadSelectedNote() }
    @IBAction func copyURL(_ sender: Any?) { model.copyNoteURL() }
    @IBAction func copyPath(_ sender: Any?) { model.copyNotePaths(model.selectedNotes) }

    /// Edit ▸ Copy is `noteCopy:`, which the storyboard window routes by
    /// focus: the editor copies its selection, the preview its selection,
    /// any other text field its own, the note list the whole note.
    @IBAction func noteCopy(_ sender: Any?) {
        guard let responder = window?.firstResponder else { return }
        if let text = responder as? NSTextView {
            text.copy(sender)
        } else if let preview = model.preview, let view = responder as? NSView,
            view === preview || view.isDescendant(of: preview)
        {
            preview.copySelectionToPasteboard()
        } else if column(of: responder) == .nav, let note = model.selectedNote {
            note.ensureContentLoaded()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.content.string, forType: .string)
        }
    }

    private var settingsObserver: NSObjectProtocol?
    private var fontSetObserver: NSObjectProtocol?

    // MARK: Export

    @IBAction func exportPdf(_ sender: Any?) { model.export(.pdf) }
    @IBAction func exportImage(_ sender: Any?) { model.export(.image) }
    @IBAction func exportHtml(_ sender: Any?) { model.export(.html) }

    /// File ▸ Export: the formats as a menu at the open note's row.
    @IBAction func exportMenu(_ sender: Any?) {
        guard model.selectedNote != nil else { return }
        popUpAtSelectedRow(Self.exportFormatsMenu())
    }

    /// A File menu submenu at the open note's row, the way the storyboard
    /// window pops its note menu's submenus; at the pointer when the list is
    /// hidden or the row is scrolled away.
    private func popUpAtSelectedRow(_ menu: NSMenu) {
        guard let window, let view = window.contentView else { return }
        if model.layout != .noteOnly, let row = model.selectedRowFrame,
            let items = (window.contentViewController as? NSSplitViewController)?.splitViewItems, items.count == 3,
            case let nav = items[0].viewController.view,
            nav.bounds.insetBy(dx: 0, dy: -1).contains(NSPoint(x: row.midX, y: nav.isFlipped ? row.midY : nav.bounds.height - row.midY))
        {
            // SwiftUI frames run down from the hosting view's top edge.
            let y = nav.isFlipped ? row.minY + 8 : nav.bounds.height - row.minY - 8
            menu.popUp(positioning: menu.item(at: 0), at: NSPoint(x: row.minX + 20, y: y), in: nav)
            return
        }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    static func exportFormatsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "PDF", action: #selector(exportPdf(_:)), keyEquivalent: "")
        menu.addItem(withTitle: I18n.str("Image"), action: #selector(exportImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "HTML", action: #selector(exportHtml(_:)), keyEquivalent: "")
        menu.addItem(withTitle: I18n.str("PPT PDF"), action: #selector(exportMiaoYanPPT(_:)), keyEquivalent: "")
        return menu
    }

    @IBAction func sortBy(_ sender: NSMenuItem) {
        guard let id = sender.identifier, let sort = SortBy(rawValue: String(id.rawValue.dropFirst(3))) else { return }
        model.setSort(sort)
    }

    @IBAction func sortDirectionBy(_ sender: NSMenuItem) {
        model.setSortDescending(sender.identifier?.rawValue == "Descending")
    }

    // swiftlint:disable:next cyclomatic_complexity
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasNote = model.selectedNote != nil
        switch menuItem.action {
        case #selector(sortBy(_:)):
            menuItem.state = menuItem.identifier?.rawValue == "SB.\(UserDefaultsManagement.sort.rawValue)" ? .on : .off
            return true
        case #selector(sortDirectionBy(_:)):
            let descending = menuItem.identifier?.rawValue == "Descending"
            menuItem.state = descending == UserDefaultsManagement.sortDirection ? .on : .off
            return true
        // An export captures the preview or the deck it opened, so the mode
        // stays put until the file is written.
        case #selector(togglePreview(_:)), #selector(toggleEditorMode(_:)):
            menuItem.state = model.editorMode == .preview ? .on : .off
            return hasNote && !model.isPresenting && !model.isExporting
        case #selector(toggleOutlinePanel(_:)):
            // Command-5 during a deck would slide the column over the slides.
            menuItem.state = model.isOutlineVisible ? .on : .off
            return !model.isPresenting
        case #selector(AppDelegate.changeAppearance(_:)):
            // 外观子菜单的勾选态：跟随系统/浅色/深色按 rawValue 匹配。
            let appearanceRaw = UserDefaultsManagement.appearanceType.rawValue
            let expected = switch appearanceRaw {
            case 1: "ap.light"
            case 2: "ap.dark"
            default: "ap.system"
            }
            menuItem.state = menuItem.identifier?.rawValue == expected ? .on : .off
            return true
        case #selector(togglePresentation(_:)):
            // Command-4 also leaves a PPT deck, as in the storyboard window.
            menuItem.state = model.isPresenting && !model.isPPT ? .on : .off
            return hasNote && !model.isExporting
        case #selector(toggleMagicPPT(_:)):
            menuItem.state = model.isPPT ? .on : .off
            return hasNote && (!model.isPresenting || model.isPPT) && !model.isExporting
        case #selector(toggleTOC(_:)):
            // Reveal's deck has no table of contents.
            return hasNote && model.editorMode != .edit && !model.isPPT
        case #selector(formatText(_:)), #selector(cleanTypography(_:)):
            return hasNote && model.editorMode != .preview && !model.isPresenting && !model.isExporting
        // Removing the note being exported would leave the export nothing to write.
        case #selector(deleteNote(_:)):
            return hasNote && !model.isPresenting && !model.isExporting
        case #selector(duplicate(_:)):
            return hasNote && model.selectedNote?.isTrash() == false && !model.isPresenting
        case #selector(noteCopy(_:)):
            return hasNote || window?.firstResponder is NSTextView
        case #selector(reloadCurrentNote(_:)), #selector(copyURL(_:)), #selector(copyPath(_:)):
            return hasNote
        case #selector(exportMiaoYanPPT(_:)):
            return hasNote && !model.isExporting && (!model.isPresenting || model.isPPT) && model.selectedNoteHasSlides
        case #selector(showInfo(_:)):
            return hasNote && !model.isPresenting
        case #selector(showVersionHistory(_:)):
            return hasNote && model.selectedNote?.isTrash() == false && !model.isPresenting
        case #selector(textFinder(_:)):
            return hasNote
        case #selector(renameFolderMenu(_:)):
            return model.selectedFolder != nil && model.layout == .all && !model.isPresenting
        case #selector(revealFolderMenu(_:)):
            return sidebarFolderURL != nil && !model.isPresenting
        case #selector(deleteFolderMenu(_:)):
            return (model.selectedFolder.map { !$0.isDefault && !$0.isRoot } ?? false) && !model.isPresenting
                && !model.isExporting
        // The storyboard window's canUseMenu: nothing that changes the
        // library or the open note while presenting.
        case #selector(fileMenuNewNote(_:)), #selector(searchNotes(_:)), #selector(singleOpen(_:)),
            #selector(importFiles(_:)), #selector(newFolderMenu(_:)), #selector(cleanUnusedAttachments(_:)):
            return !model.isPresenting
        case #selector(moveMenu(_:)):
            // Notes in the Trash can move back out by this menu too.
            return hasNote && !model.isPresenting && !model.isExporting
        case #selector(exportPdf(_:)), #selector(exportImage(_:)), #selector(exportHtml(_:)), #selector(exportMenu(_:)):
            return hasNote && !model.isExporting
        case #selector(finderMenu(_:)):
            if column(of: window?.firstResponder) == .nav { return sidebarFolderURL != nil && !model.isPresenting }
            return hasNote && !model.isPresenting
        case #selector(openInTerminal(_:)):
            return terminalURL != nil
        case #selector(renameMenu(_:)), #selector(pinMenu(_:)):
            return hasNote && !model.isPresenting
        default:
            return true
        }
    }

    // MARK: - Keyboard

    private enum Column {
        case nav
        case detail
        case outline
    }

    /// Which column holds `responder`; a text field's editor sits inside it.
    private func column(of responder: NSResponder?) -> Column? {
        guard let view = responder as? NSView,
            let items = (window?.contentViewController as? NSSplitViewController)?.splitViewItems, items.count == 3
        else { return nil }
        let columns: [Column] = [.nav, .detail, .outline]
        return zip(items, columns).first { view.isDescendant(of: $0.0.viewController.view) }?.1
    }

    /// Option-Command-I opens and closes the note's info.
    private func toggleInfo() {
        if infoPopover.isShown {
            infoPopover.performClose(nil)
        } else {
            showInfo(nil)
        }
    }

    /// Set when Escape goes down in the editor with nothing of its own to
    /// cancel (an input method, a find bar); its key-up then moves focus to
    /// the list, as `EditTextView.keyUp` does in the storyboard window.
    private var escapeLeavesEditor = false

    // The storyboard window's `handleKeyDown` shortcuts that no menu item
    // carries. Returns nil for a key it used.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.attachedSheet == nil else { return event }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let responder = window.firstResponder
        let editor = model.editor.textView
        let isText = responder is NSTextView
        let hasNote = model.selectedNote != nil
        let column = column(of: responder)
        // The navigation column's only text field is the folder-rename field
        // (the list's search field was retired with the merged column).
        let inSearch = isText && column == .nav
        let inNav = !isText && column == .nav

        if handleColumnKey(event, flags: flags, inSearch: inSearch, inNav: inNav) {
            return nil
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            escapeLeavesEditor =
                flags.isEmpty && responder === editor && !editor.hasMarkedText() && !editor.isSearchBarVisible
            return event
        case kVK_ANSI_S where flags == [.command]:
            // A title being edited is committed first, as the storyboard's
            // Command-S does through fileName(_:).
            if model.isRenaming, isText, responder !== editor, column == .detail { leaveTitleField() }
            model.saveNow()
            return nil
        case kVK_ANSI_W where flags == [.command, .shift] && model.isSingleMode:
            model.closeSingle()
            return nil
        case kVK_ANSI_H where flags == [.command, .shift]:
            guard model.selectedNote?.isTrash() == false, !model.isPresenting else { return event }
            model.showVersionHistory()
            return nil
        case kVK_ANSI_H where flags == [.control, .shift]:
            guard hasNote, !model.isExporting else { return event }
            model.export(.html)
            return nil
        // The storyboard list's export keys: PDF, image and the PPT deck, from
        // the list only, as in NotesTableView.keyUp. Text keeps them
        // (Control-Shift-P extends a selection up).
        case kVK_ANSI_P where flags == [.control, .shift]:
            guard hasNote, !isText, column == .nav, !model.isExporting, !model.isPPT else { return event }
            model.export(.pdf)
            return nil
        case kVK_ANSI_I where flags == [.control, .shift]:
            guard hasNote, !isText, column == .nav, !model.isExporting, !model.isPPT else { return event }
            model.export(.image)
            return nil
        case kVK_ANSI_P where flags == [.control, .option, .shift]:
            guard hasNote, !isText, column == .nav, !model.isExporting, !model.isPPT else { return event }
            model.export(.ppt)
            return nil
        case kVK_ANSI_I where flags == [.command, .option]:
            guard hasNote, !model.isPresenting else { return event }
            toggleInfo()
            return nil
        case kVK_ANSI_U where flags == [.command, .option]:
            guard hasNote else { return event }
            model.copyNoteURL()
            return nil
        case kVK_ANSI_C where flags == [.command, .option]:
            guard hasNote else { return event }
            model.copyNotePaths(model.selectedNotes)
            return nil
        case kVK_ANSI_Equal where flags == [.command]:
            // The View menu's Zoom In carries "+" (Command-Shift-=); this
            // adds the bare Command-=.
            model.adjustFontSize(by: 1)
            return nil
        case kVK_ANSI_Z where flags == [.command] && responder === editor:
            model.editor.keepCursorThroughFormatUndo()
            return event
        // Outside text, Command-Z puts deleted notes back. Left to the
        // responder chain it could stop at a SwiftUI view or the editor's
        // per-note manager, and the undo did nothing.
        case kVK_ANSI_Z where flags == [.command] && !isText && model.notesUndoManager.canUndo:
            model.notesUndoManager.undo()
            return nil
        case kVK_Delete where flags == [.command] && isText:
            // Text keeps Command-Delete: the editor deletes to the start of
            // the line, the title and search fields clear.
            if responder === editor {
                editor.deleteToBeginningOfLine(nil)
            } else if let field = responder as? NSTextView {
                field.selectAll(nil)
                field.deleteBackward(nil)
            }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.isPPT {
                // The overview would be printed in place of the slides.
                if !model.isExporting {
                    model.preview?.evaluateJavaScript("Reveal.toggleOverview();", completionHandler: nil)
                }
                return nil
            }
            // Fields submit on Return; the editor types it. A note row's
            // Return opens the note in the editor.
            guard !isText else { return event }
            guard flags.isEmpty else { return event }
            if column == .nav, hasNote, model.editorMode != .preview {
                model.focusEditor()
                return nil
            }
            return event
        case kVK_Tab:
            if flags == [.control], model.layout != .noteOnly {
                model.focusRequest = .list
                return nil
            }
            guard flags.isEmpty else { return event }
            if model.isRenaming, isText, responder !== editor, column == .detail,
                (responder as? NSTextView)?.hasMarkedText() != true
            {
                leaveTitleField()
                return nil
            }
            return event
        default:
            break
        }

        if flags == [.command], event.charactersIgnoringModifiers == "." {
            // Command-. cancels what is in progress: a rename, a find bar,
            // the list's search.
            if model.renamingFolderURL != nil {
                model.renamingFolderURL = nil
                return nil
            }
            if model.isRenaming {
                model.isRenaming = false
                model.focusRequest = .list
                return nil
            }
            if editor.isSearchBarVisible {
                editor.hideSearchBar()
                return nil
            }
            if let preview = model.preview, preview.isSearchBarVisible {
                preview.hideSearchBar()
                return nil
            }
            // Nothing to cancel: the storyboard window ended in its search
            // field. It also closed the open note there, which the shell
            // keeps: its list opens a note again on the next refresh.
            if !model.isPresenting, model.isPaletteOpen,
                (responder as? NSTextView)?.hasMarkedText() != true
            {
                model.closePalette()
                return nil
            }
        }
        return event
    }

    /// Leaving the title field commits it, then the editor takes the keys.
    private func leaveTitleField() {
        if model.editorMode == .preview {
            window?.makeFirstResponder(nil)
        } else {
            model.focusEditor()
        }
    }

    // Keys the merged navigation column takes for itself, folded from the
    // storyboard window's search field (SearchTextField), note list
    // (NotesTableView.keyUp) and sidebar (SidebarProjectView.keyDown).
    // True when the key was used.
    // swiftlint:disable:next cyclomatic_complexity
    private func handleColumnKey(
        _ event: NSEvent, flags: NSEvent.ModifierFlags, inSearch: Bool, inNav: Bool
    ) -> Bool {
        guard !model.isPresenting, inSearch || inNav else { return false }
        let key = Int(event.keyCode)

        if inNav {
            switch key {
            case kVK_RightArrow where flags.isEmpty:
                // Right expands the chosen folder; its notes are the rows
                // under it already.
                model.setChosenFolderExpanded(true)
                return true
            case kVK_LeftArrow where flags.isEmpty:
                model.setChosenFolderExpanded(false)
                return true
            case kVK_Tab where flags.isEmpty:
                // The preview has no editor to take focus; keep the key.
                guard model.editorMode != .preview else { return false }
                if model.selectedNote == nil { model.selectNext(1) }
                model.focusEditor()
                return true
            case kVK_ANSI_A where flags == [.command]:
                model.selectAllNotes()
                return true
            case kVK_F6 where flags == [.shift]:
                guard let folder = model.selectedFolder, !folder.isDefault, !folder.isRoot else { return true }
                model.renamingFolderURL = folder.url
                return true
            case kVK_Delete where flags == [.command, .shift]:
                if let folder = model.selectedFolder { model.confirmDeleteFolder(folder) }
                return true
            default:
                break
            }
        }

        // Typing a letter or digit in the navigation column opens the
        // palette seeded with it, as the old list filter did — except while
        // the folder-rename field is up: those keys belong to the rename.
        if flags.isDisjoint(with: [.command, .control]), let typed = event.characters,
            Self.seedsPalette(with: typed, isRenamingFolder: model.renamingFolderURL != nil)
        {
            model.openPalette(query: typed)
            return true
        }
        return false
    }

    /// Whether a typed character in the navigation column opens the palette.
    /// The folder-rename field is the column's one text field; its keystrokes
    /// are the rename, not a query.
    nonisolated static func seedsPalette(with typed: String, isRenamingFolder: Bool) -> Bool {
        guard !isRenamingFolder, !typed.isEmpty else { return false }
        return CharacterSet(charactersIn: typed).isSubset(of: .alphanumerics)
    }

    // MARK: - Swipe

    private var swipeDeltaX: CGFloat = 0
    private var isTrackingSwipe = false
    private var swipedLeft = false
    private var swipedRight = false

    /// ViewController+Layout's two-finger swipe: left hides the folders, then
    /// the list; right brings them back. A swipe that starts over the
    /// preview is left to it, since wide tables and code scroll sideways.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, let window, event.window === window,
            event.hasPreciseScrollingDeltas
        else { return event }
        switch event.phase {
        case .began:
            isTrackingSwipe = !isOverPreview(event)
            swipedLeft = false
            swipedRight = false
            swipeDeltaX = 0
        case .changed:
            guard isTrackingSwipe, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { break }
            guard swipeDeltaX.sign == event.scrollingDeltaX.sign else {
                swipeDeltaX = event.scrollingDeltaX
                break
            }
            swipeDeltaX += event.scrollingDeltaX
            guard abs(swipeDeltaX) > 50 else { break }
            let left = swipeDeltaX < 0
            if left, !swipedLeft {
                swipedLeft = true
                swipedRight = false
            } else if !left, !swipedRight {
                swipedRight = true
                swipedLeft = false
            } else {
                break
            }
            model.swipeColumns(left: left)
            return nil
        case .ended, .cancelled, .mayBegin:
            isTrackingSwipe = false
        default:
            break
        }
        return event
    }

    /// A right-click or Control-click chooses the row under the pointer
    /// before SwiftUI opens its menu, as the storyboard sidebar's
    /// willOpenMenu and the note list's menu do: a folder switches the list,
    /// a note outside the selection becomes the selection.
    private func handleMenuClick(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.attachedSheet == nil,
            event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        else { return event }
        if let row = model.hoveredSidebarRow,
            let sidebar = (window.contentViewController as? NSSplitViewController)?.splitViewItems.first?.viewController.view,
            !sidebar.isHiddenOrHasHiddenAncestor,
            sidebar.bounds.contains(sidebar.convert(event.locationInWindow, from: nil))
        {
            model.scope = row
        } else if let url = model.hoveredNoteURL,
            column(of: window.contentView?.hitTest(event.locationInWindow)) == .nav,
            let note = model.notes.first(where: { $0.url == url })
        {
            model.selectForMenu(note)
        }
        return event
    }

    private func isOverPreview(_ event: NSEvent) -> Bool {
        guard let preview = model.preview, preview.window === window, !preview.isHiddenOrHasHiddenAncestor else { return false }
        return preview.bounds.contains(preview.convert(event.locationInWindow, from: nil))
    }

    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == kVK_Escape, escapeLeavesEditor else { return event }
        escapeLeavesEditor = false
        guard let window, event.window === window, window.firstResponder === model.editor.textView,
            model.layout != .noteOnly
        else { return event }
        model.focusRequest = .list
        return nil
    }

    // MARK: - Disk changes

    private var fsManager: FileSystemEventManager?
    private var fsResumeTimer: Timer?

    /// The storyboard window's rule: while an edit is being saved, ignore disk
    /// events briefly so the save itself does not reload the note under the
    /// cursor (destructive mid IME composition), then re-check once.
    private func blockFSUpdates() {
        AppEnvironment.current.userData.fsUpdatesDisabled = true
        fsResumeTimer?.invalidate()
        fsResumeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                AppEnvironment.current.userData.fsUpdatesDisabled = false
                if let note = EditTextView.note {
                    self?.fsManager?.recheckNote(note)
                }
            }
        }
    }

    // MARK: - Window level and activation

    private var windowLevelObserver: NSObjectProtocol?

    /// View ▸ Always on Top, applied the way `MainWindowController` does.
    private func applyWindowLevel() {
        window?.level = UserDefaultsManagement.alwaysOnTop ? .floating : .normal
    }

    /// The activate shortcut and Window ▸ Active Window: hide MiaoYan when it
    /// is already in front, otherwise bring this window forward.
    func toggleFrontmost() {
        guard let window else { return }
        if NSApp.isActive, !NSApp.isHidden, !window.isMiniaturized {
            NSApp.hide(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    /// Closed while full screen, the window comes back full screen, as the
    /// storyboard window does from `sessionFullScreenMode`. Full screen that
    /// a presentation entered ends with it and is not restored.
    private var reopensInFullScreen = false

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard reopensInFullScreen, let window else { return }
        reopensInFullScreen = false
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Trackers such as Hina read AXDocument to see which note is open. The
    /// storyboard window sets it from `EditTextView.note`, which in preview
    /// may not follow the list here, so the shell uses its own open note and
    /// clears it when none is open. No representedURL: that adds a title
    /// bar icon.
    private func observeOpenNote() {
        let url = withObservationTracking {
            model.selectedNote?.url
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOpenNote() }
        }
        let document = url?.absoluteString
        if window?.accessibilityDocument() != document { window?.setAccessibilityDocument(document) }
    }

    // MARK: - Presentation

    private var escapeMonitor: Any?

    /// Presentation fills the screen; leaving full screen by any route, or
    /// pressing Escape, ends it.
    func observePresentation() {
        let presenting = withObservationTracking {
            model.isPresenting
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePresentation() }
        }
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if presenting {
            if !isFullScreen { window.toggleFullScreen(nil) }
            escapeMonitor =
                escapeMonitor
                ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53, let self, self.model.isPresenting else { return event }
                    // A deck being exported stays up until it is printed.
                    if !self.model.isExporting { self.model.setPresenting(false) }
                    return nil
                }
        } else {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            if isFullScreen, didEnterFullScreenForPresentation {
                isLeavingFullScreenForPresentation = true
                window.toggleFullScreen(nil)
            }
        }
    }

    private var didEnterFullScreenForPresentation = false
    /// Set while this controller itself leaves full screen at the end of a
    /// presentation, so the exit callback does not end a presentation that
    /// was started again before the animation finished.
    private var isLeavingFullScreenForPresentation = false

    /// Full screen draws even an empty toolbar as a solid band over the
    /// content, and it only sizes the title bar, so it waits outside.
    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = false
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        didEnterFullScreenForPresentation = model.isPresenting
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
        didEnterFullScreenForPresentation = false
        if isLeavingFullScreenForPresentation {
            isLeavingFullScreenForPresentation = false
            // A presentation started again during the exit animation wants
            // full screen back.
            if model.isPresenting { window?.toggleFullScreen(nil) }
            return
        }
        model.setPresenting(false)
    }

    func windowWillClose(_ notification: Notification) {
        reopensInFullScreen = window?.styleMask.contains(.fullScreen) == true && !didEnterFullScreenForPresentation
        model.setPresenting(false)
        // The palette is a child panel that merely gets ordered out with the
        // shell; leaving the model flag open made the first ⌘K after reopening
        // only close it.
        model.closePalette()
        flushEdits()
    }

    private var lastResignKeyFlushAt: TimeInterval = 0

    /// Losing key can be the last moment before a kill, so the open note's
    /// pending save is written now. Spotlight, open panels and permission
    /// prompts take key too, so as in MainWindowController this runs at most
    /// every two seconds and writes only the note being edited.
    func windowDidResignKey(_ notification: Notification) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastResignKeyFlushAt >= 2 else { return }
        lastResignKeyFlushAt = now
        guard let note = model.editor.textView.storageNote ?? EditTextView.note, note.needsSave else { return }
        note.flushPendingSave()
    }

    /// The list's undo (a delete) for everything but the editor, whose text
    /// view asks its delegate for the note's own undo manager first.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.notesUndoManager
    }

    /// MainWindowController's rule: a Custom appearance keeps its own colours
    /// whatever the system switches to. Light and Dark only change through
    /// Settings, which this follows.
    private func appearanceDidChange() {
        guard let window, UserDefaultsManagement.appearanceType != .Custom else { return }
        AppEnvironment.current.userData.isDark = window.effectiveAppearance.isDark
        NotesTextProcessor.hl = nil
        if let note = model.editor.textView.storageNote {
            NotesTextProcessor.highlight(note: note)
            model.editor.reload(note)
        }
        model.preview?.updateAppearance()
    }

    /// `ShellModel.flushEdits`, for the app delegate's terminate path.
    func flushEdits() {
        model.flushEdits()
    }
}

@available(macOS 14, *)
extension ShellWindowController: FileSystemEventHost {
    func fsReloadList(selecting note: Note?, completion: (@MainActor @Sendable () -> Void)?) {
        model.reload()
        model.refreshNow(selecting: note?.url) { completion?() }
    }

    func fsInsert(_ note: Note) { model.refreshNow() }
    func fsReloadSidebar() { model.reload() }

    func fsSelectFirstNote() {
        model.selectedNoteURL = model.notes.first?.url
    }

    func fsRemove(_ notes: [Note]) { model.refreshNow() }

    func fsReload(_ note: Note) {
        model.noteChangedOnDisk(note)
    }

    func fsRefillEditor() {
        guard let note = EditTextView.note else { return }
        model.editor.reload(note)
    }

    var fsEditorBuffer: (owner: Note?, text: String)? {
        (model.editor.textView.storageNote, model.editor.textView.string)
    }

    func fsToast(_ message: String, style: ToastStyle) {
        model.host?.toast(message: message, style: style)
    }
}

/// Navigation, the open note and the outline side by side. The split stays
/// AppKit so the panes keep their widths when the window resizes and the
/// dividers are remembered; each pane is SwiftUI. Plain split items, not the
/// sidebar kind, so no translucent material appears behind the rows.
@available(macOS 14, *)
final class ShellSplitViewController: NSSplitViewController {
    private let model: ShellModel

    init(model: ShellModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        splitView = ShellSplitView()
        super.loadView()
    }

    override func viewDidLoad() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        // The middle pane takes the window's bulk: the columns cap at
        // comfortable reading widths and everything else falls to the editor.
        let nav = NSSplitViewItem(viewController: Self.host(ShellNav(model: model)))
        nav.minimumThickness = 200
        nav.maximumThickness = 300
        nav.canCollapse = true
        nav.holdingPriority = NSLayoutConstraint.Priority(260)

        let detail = NSSplitViewItem(viewController: Self.host(ShellDetail(model: model)))
        detail.minimumThickness = 320
        detail.holdingPriority = NSLayoutConstraint.Priority(250)

        let outline = NSSplitViewItem(viewController: Self.host(ShellOutline(model: model)))
        outline.minimumThickness = ShellModel.outlineMinWidth
        outline.maximumThickness = ShellModel.outlineMaxWidth
        outline.canCollapse = true
        outline.holdingPriority = NSLayoutConstraint.Priority(240)

        for item in [nav, detail, outline] {
            addSplitViewItem(item)
        }
        // The outline starts collapsed unless the last session left it open.
        outline.isCollapsed = !model.isOutlineVisible
        splitView.autosaveName = "MiaoYanShellSplitV2"
        super.viewDidLoad()
        model.host = self
        ExportHosts.shell = self
        observeLayout()
        observeOutlineVisibility()
        observeOutlineWidth()
        observeDividerDrags()
    }

    /// Collapses the navigation column as its toggle asks.
    private func observeLayout() {
        let layout = withObservationTracking {
            model.layout
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLayout() }
        }
        let items = splitViewItems
        guard items.count == 3 else { return }
        let navCollapsed = layout != .all
        guard items[0].isCollapsed != navCollapsed else {
            model.layoutDidSettle()
            return
        }
        isApplyingLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.change
            context.timingFunction = Theme.Motion.curve
            items[0].animator().isCollapsed = navCollapsed
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isApplyingLayout = false
                self?.model.layoutDidSettle()
                // Collapsing the navigation column is Command-1's whole job:
                // the list had the keys, and typing right after it has to
                // land in the editor.
                if navCollapsed { self?.model.focusEditor() }
            }
        }
    }

    /// The outline column follows the model's visibility flag, and hides
    /// outright when no note is open — an empty pane beside a blank editor,
    /// with its divider, was pure noise.
    private func observeOutlineVisibility() {
        // This toolchain's withObservationTracking hands the apply closure's
        // return value back, so both tracked values ride out in a tuple.
        let (outlineOn, hasNote) = withObservationTracking {
            (model.isOutlineVisible, model.selectedNoteURL != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOutlineVisibility() }
        }
        let visible = outlineOn && hasNote
        let items = splitViewItems
        guard items.count == 3 else { return }
        // Detect first, mutate only inside the animation group: an early
        // synchronous `isCollapsed =` collapsed the pane instantly and the
        // later animator call became a no-op — the empty-scope jump. The
        // hidden flag stays synchronous; it is the alpha animation's state.
        let collapseNeeded = items[2].isCollapsed != !visible
        let outlineView = items[2].viewController.view
        let hideNeeded = outlineView.isHidden == visible
        if hideNeeded { outlineView.isHidden = !visible }
        guard collapseNeeded || hideNeeded else { return }
        isApplyingLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.change
            context.timingFunction = Theme.Motion.curve
            if collapseNeeded {
                items[2].animator().isCollapsed = !visible
            }
            if hideNeeded {
                outlineView.animator().alphaValue = visible ? 1 : 0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // A fresh expand lands at the minimum thickness; the fitted
                // content width takes it from there. syncOutlineWidth owns
                // the layout flag.
                if visible, let self {
                    self.syncOutlineWidth(hysteresis: 1)
                } else if let self {
                    self.isApplyingLayout = false
                }
            }
        }
    }

    /// Fits the outline pane to its widest heading when the heading set
    /// changes. The 24pt hysteresis (the expand pass tightens it to 1pt)
    /// keeps a heading being typed from walking the divider — only a
    /// decisively wider or narrower set of headings moves the column.
    private func observeOutlineWidth() {
        let (entries, visible, hasNote) = withObservationTracking {
            (model.outline, model.isOutlineVisible, model.selectedNoteURL != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOutlineWidth() }
        }
        guard visible, hasNote, entries != fittedOutline else { return }
        fittedOutline = entries
        syncOutlineWidth(hysteresis: 24)
    }

    private var fittedOutline: [ShellModel.OutlineEntry] = []

    private func syncOutlineWidth(hysteresis: CGFloat) {
        let items = splitViewItems
        let width = model.outlineContentWidth
        let needsMove = items.count == 3 && !items[2].isCollapsed
            && abs(items[2].viewController.view.frame.width - width) >= hysteresis
        isApplyingLayout = true
        guard needsMove else {
            isApplyingLayout = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.change
            context.timingFunction = Theme.Motion.curve
            context.allowsImplicitAnimation = true
            self.splitView.setPosition(self.splitView.bounds.width - width, ofDividerAt: 1)
            self.splitView.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.isApplyingLayout = false }
        }
    }

    private var isApplyingLayout = false
    private var resizeObserver: NSObjectProtocol?

    /// A column dragged shut, or back open, moves the model's flags with it,
    /// so the toggles and header buttons agree with what is on screen: the
    /// navigation drag drives the layout, the outline drag its visibility.
    private func observeDividerDrags() {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isApplyingLayout, self.splitViewItems.count == 3 else { return }
                let items = self.splitViewItems
                self.model.syncLayout(navCollapsed: items[0].isCollapsed)
                let outlineShown = !items[2].isCollapsed
                if self.model.isOutlineVisible != outlineShown {
                    self.model.isOutlineVisible = outlineShown
                }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppliedDefaultWidths else { return }
        hasAppliedDefaultWidths = true
        // First launch only: the autosaved positions win afterwards.
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MiaoYanShellSplitV2") == nil {
            splitView.setPosition(240, ofDividerAt: 0)
        }
    }

    private var hasAppliedDefaultWidths = false

    /// Without clearing `sizingOptions` the hosting controllers would size
    /// the panes to their SwiftUI content instead of leaving that to the split.
    private static func host(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        return controller
    }
}

/// Every column shares one tone, so each divider is a hairline.
@available(macOS 14, *)
final class ShellSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        ShellPalette.background.setFill()
        rect.fill()
        ShellPalette.hairline.setFill()
        rect.fill(using: .sourceOver)
    }
}

/// The empty part of a column's header, which is the title bar's band: a
/// drag moves the window and a double-click does what System Settings asks of
/// a title bar, as the storyboard window's `MainWindow.mouseUp` does. Placed
/// behind a header's content, so its buttons, title and fields keep their own
/// clicks; the SwiftUI pane above it would otherwise take every click there.
@available(macOS 14, *)
struct ShellTitleBarArea: NSViewRepresentable {
    enum DoubleClick: Equatable {
        case zoom
        case minimize
        case none
    }

    /// "Double-click a window's title bar to" in Desktop & Dock: Zoom (and
    /// Fill, which has no public call) when unset, or the older Minimize
    /// switch when only that is set.
    static func doubleClick(action: String?, legacyMinimize: Bool) -> DoubleClick {
        switch action {
        case "Minimize": return .minimize
        case "None": return .none
        case nil: return legacyMinimize ? .minimize : .zoom
        default: return .zoom
        }
    }

    final class AreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            // The second click acts on mouse up and must not start a drag.
            guard event.clickCount < 2 else { return }
            window?.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard event.clickCount >= 2, let window, !window.styleMask.contains(.fullScreen) else { return }
            let defaults = UserDefaults.standard
            switch ShellTitleBarArea.doubleClick(
                action: defaults.string(forKey: "AppleActionOnDoubleClick"),
                legacyMinimize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
            {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        }
    }

    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ nsView: AreaView, context: Context) {}
}

/// Exports report here: the open note, its title, progress toasts, and the
/// mode to return to once the file is written.
@available(macOS 14, *)
extension ShellSplitViewController: ExportHost {
    var exportNote: Note? { model.selectedNote }
    var exportTitle: String { model.selectedNote?.getTitleWithoutLabel() ?? "" }

    func toastExport(status: Bool) {
        if status {
            toast(message: I18n.str("Saved to Downloads"), style: .success)
        } else {
            toast(message: I18n.str("Export failed"), style: .failure)
        }
        endExport()
    }

    func endExport() { model.finishExport() }

    func finishPPTExport() { model.finishPPTExport() }
}
