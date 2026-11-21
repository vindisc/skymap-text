import AppKit

/// Builds the application menu programmatically for the SwiftPM build, which
/// has no Main.storyboard to supply one. The selector and key-equivalent set
/// mirrors the storyboard menu so the shell window, the editor and the
/// `AppDelegate` answer the same commands: items use nil targets and AppKit
/// routes them through the responder chain, disabling items nobody answers.
@MainActor
enum MainMenuBuilder {
    /// Resolves a menu title: `Localizable.strings` first, then the storyboard
    /// `Main.strings` table, then the key itself as the English fallback.
    private static func title(_ key: String) -> String {
        let localized = I18n.str(key)
        if localized != key { return localized }
        return Bundle.main.localizedString(forKey: key, value: key, table: "Main")
    }

    private static func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        identifier: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return item
    }

    static func install() {
        let main = NSMenu()

        // MARK: App menu

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let app = NSMenu(title: "SkymapText")
        appMenuItem.submenu = app

        app.addItem(item(title("About"), action: #selector(AppDelegate.showAboutWindow(_:))))
        app.addItem(.separator())
        app.addItem(item(title("Settings…"), action: #selector(AppDelegate.openPreferences(_:)), key: ","))
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            app.addItem(item(title("Check for Updates…"), action: #selector(AppDelegate.checkForUpdates(_:))))
        }
        app.addItem(.separator())
        app.addItem(item(title("Hide SkymapText"), action: #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(item(title("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        app.addItem(item(title("Show All"), action: #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(title("Quit SkymapText"), action: #selector(AppDelegate.quiteApp(_:)), key: "q"))

        // MARK: File menu

        let fileMenuItem = NSMenuItem()
        main.addItem(fileMenuItem)
        let file = NSMenu(title: title("File"))
        fileMenuItem.submenu = file

        file.addItem(item(title("New Note"), action: #selector(ShellWindowController.fileMenuNewNote(_:)), key: "n"))
        file.addItem(item(title("New Folder"), action: #selector(ShellWindowController.newFolderMenu(_:)), key: "N"))
        file.addItem(item(title("Single Mode"), action: #selector(ShellWindowController.singleOpen(_:)), key: "o"))
        file.addItem(item(title("Import…"), action: #selector(ShellWindowController.importFiles(_:))))
        file.addItem(.separator())
        file.addItem(item(title("Duplicate"), action: #selector(ShellWindowController.duplicate(_:)), key: "d"))
        file.addItem(item(title("Rename"), action: #selector(ShellWindowController.renameMenu(_:)), key: "r"))
        file.addItem(item(title("Pin Note"), action: #selector(ShellWindowController.pinMenu(_:)), key: "P"))
        file.addItem(item(title("Reload Note"), action: #selector(ShellWindowController.reloadCurrentNote(_:)), key: "R"))
        file.addItem(item(title("Show Info"), action: #selector(ShellWindowController.showInfo(_:)), key: "i", modifiers: [.command, .option]))
        file.addItem(item(title("Version History"), action: #selector(ShellWindowController.showVersionHistory(_:))))
        file.addItem(.separator())
        file.addItem(item(title("Move to Folder…"), action: #selector(ShellWindowController.moveMenu(_:))))
        file.addItem(item(title("Reveal in Finder"), action: #selector(ShellWindowController.finderMenu(_:)), key: "r", modifiers: [.command, .option]))
        file.addItem(item(title("Open in Terminal"), action: #selector(ShellWindowController.openInTerminal(_:)), key: "j"))
        file.addItem(item(title("Clean Unused Attachments"), action: #selector(ShellWindowController.cleanUnusedAttachments(_:))))
        file.addItem(.separator())
        file.addItem(item(title("Delete Note"), action: #selector(ShellWindowController.deleteNote(_:))))

        // MARK: Export submenu

        let exportMenuItem = NSMenuItem(title: title("Export"), action: nil, keyEquivalent: "")
        let export = NSMenu(title: title("Export"))
        exportMenuItem.submenu = export
        export.addItem(item("HTML", action: #selector(ShellWindowController.exportHtml(_:)), key: "H", modifiers: [.control]))
        export.addItem(item("Image", action: #selector(ShellWindowController.exportImage(_:)), key: "I", modifiers: [.control]))
        export.addItem(item("PDF", action: #selector(ShellWindowController.exportPdf(_:)), key: "P", modifiers: [.control]))
        export.addItem(item(title("MiaoYan PPT"), action: #selector(ShellWindowController.exportMiaoYanPPT(_:))))
        file.addItem(exportMenuItem)

        // MARK: Edit menu

        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let edit = NSMenu(title: title("Edit"))
        editMenuItem.submenu = edit

        edit.addItem(item(title("Undo"), action: Selector(("undo:")), key: "z"))
        edit.addItem(item(title("Redo"), action: Selector(("redo:")), key: "Z"))
        edit.addItem(.separator())
        edit.addItem(item(title("Cut"), action: Selector(("cut:")), key: "x"))
        edit.addItem(item(title("Copy Note"), action: #selector(ShellWindowController.noteCopy(_:)), key: "c"))
        edit.addItem(item(title("Paste"), action: Selector(("paste:")), key: "v"))
        edit.addItem(item(title("Paste and Match Style"), action: Selector(("pasteAsPlainText:")), key: "V"))
        edit.addItem(item(title("Select All"), action: Selector(("selectAll:")), key: "a"))
        edit.addItem(.separator())

        let findMenuItem = NSMenuItem(title: title("Find"), action: nil, keyEquivalent: "")
        let find = NSMenu(title: title("Find"))
        findMenuItem.submenu = find
        find.addItem(item(title("Find…"), action: #selector(ShellWindowController.textFinder(_:)), key: "f"))
        find.addItem(item(title("Find and Replace…"), action: #selector(ShellWindowController.textFinder(_:)), key: "f", modifiers: [.command, .option]))
        find.addItem(item(title("Find Next"), action: #selector(ShellWindowController.textFinder(_:)), key: "g"))
        find.addItem(item(title("Find Previous"), action: #selector(ShellWindowController.textFinder(_:)), key: "G"))
        find.addItem(item(title("Jump to Selection"), action: Selector(("centerSelectionInVisibleArea:")), key: "j", modifiers: [.command, .option]))
        find.addItem(item(title("Search & Create"), action: #selector(ShellWindowController.searchAndCreate(_:)), key: "/"))
        edit.addItem(findMenuItem)

        edit.addItem(.separator())
        edit.addItem(item(title("Copy URL"), action: #selector(ShellWindowController.copyURL(_:)), key: "u", modifiers: [.command, .option]))
        edit.addItem(item(title("Copy Path"), action: #selector(ShellWindowController.copyPath(_:)), key: "c", modifiers: [.command, .option]))

        // MARK: Format menu

        let formatMenuItem = NSMenuItem()
        main.addItem(formatMenuItem)
        let format = NSMenu(title: title("Format"))
        formatMenuItem.submenu = format

        format.addItem(item(title("Bold"), action: #selector(EditTextView.boldMenu(_:)), key: "b"))
        format.addItem(item(title("Italic"), action: #selector(EditTextView.italicMenu(_:)), key: "i"))
        format.addItem(item(title("Underline"), action: #selector(EditTextView.underlineMenu(_:)), key: "u"))
        format.addItem(item(title("Deleteline"), action: #selector(EditTextView.deletelineMenu(_:)), key: "X"))
        format.addItem(.separator())
        format.addItem(item(title("Link"), action: #selector(EditTextView.linkMenu(_:)), key: "k"))
        format.addItem(item(title("Todo"), action: #selector(EditTextView.todoMenu(_:)), key: "t"))
        // Inline code gave its Command-E to the editor's two-state toggle.
        format.addItem(item(title("Inline Code"), action: #selector(EditTextView.inlineCodeMenu(_:))))
        format.addItem(item(title("Code Block"), action: #selector(EditTextView.codeBlockMenu(_:)), key: "E"))
        format.addItem(.separator())

        let insertMenuItem = NSMenuItem(title: title("Insert"), action: nil, keyEquivalent: "")
        let insert = NSMenu(title: title("Insert"))
        insertMenuItem.submenu = insert
        insert.addItem(item(title("Table"), action: #selector(EditTextView.insertTableShortcut(_:))))
        insert.addItem(item(title("Task"), action: #selector(EditTextView.insertTaskShortcut(_:))))
        insert.addItem(item(title("Time"), action: #selector(EditTextView.insertTimeShortcut(_:))))
        insert.addItem(item(title("Video"), action: #selector(EditTextView.insertVideoShortcut(_:))))
        insert.addItem(item(title("Fold"), action: #selector(EditTextView.insertFoldShortcut(_:))))
        insert.addItem(item(title("Image or File"), action: #selector(EditTextView.insertImgShortcut(_:))))
        insert.addItem(.separator())
        insert.addItem(item("Mermaid", action: #selector(EditTextView.insertMermaidShortcut(_:))))
        insert.addItem(item("Markmap", action: #selector(EditTextView.insertMarkmapShortcut(_:))))
        insert.addItem(item("PlantUML", action: #selector(EditTextView.insertPlantumlShortcut(_:))))
        format.addItem(insertMenuItem)

        format.addItem(.separator())
        format.addItem(item(title("Shift Left"), action: #selector(EditTextView.shiftLeft(_:)), key: "["))
        format.addItem(item(title("Shift Right"), action: #selector(EditTextView.shiftRight(_:)), key: "]"))
        format.addItem(.separator())
        format.addItem(item(title("Format"), action: #selector(EditTextView.formatText(_:)), key: "L"))
        format.addItem(item(title("Clean Typography"), action: #selector(EditTextView.cleanTypography(_:))))
        format.addItem(.separator())
        format.addItem(item(title("Zoom In"), action: #selector(ShellWindowController.zoomInFontSize(_:)), key: "+"))
        format.addItem(item(title("Zoom Out"), action: #selector(ShellWindowController.zoomOutFontSize(_:)), key: "-"))
        format.addItem(item(title("Actual Size"), action: #selector(ShellWindowController.resetFontSize(_:)), key: "0"))

        // MARK: View menu

        let viewMenuItem = NSMenuItem()
        main.addItem(viewMenuItem)
        let view = NSMenu(title: title("View"))
        viewMenuItem.submenu = view

        // The merged window: one navigation column, an outline column and
        // the editor's two states. The split, presentation and PPT entries
        // of the storyboard window were retired with their modes.
        view.addItem(item(title("Hide/Show Navigation"), action: #selector(ShellWindowController.toggleSidebarPanel(_:)), key: "1"))
        view.addItem(item(title("Hide/Show Outline"), action: #selector(ShellWindowController.toggleOutlinePanel(_:)), key: "5"))
        view.addItem(item(title("Toggle Preview"), action: #selector(ShellWindowController.toggleEditorMode(_:)), key: "e"))
        view.addItem(.separator())

        let sortMenuItem = NSMenuItem(title: title("Sort By"), action: nil, keyEquivalent: "")
        let sort = NSMenu(title: title("Sort By"))
        sortMenuItem.submenu = sort
        sort.addItem(item(title("Title"), action: #selector(ShellWindowController.sortBy(_:)), identifier: "SB.title"))
        sort.addItem(item(title("Creation Date"), action: #selector(ShellWindowController.sortBy(_:)), identifier: "SB.creationDate"))
        sort.addItem(item(title("Modification Date"), action: #selector(ShellWindowController.sortBy(_:)), identifier: "SB.modificationDate"))
        sort.addItem(item(title("None"), action: #selector(ShellWindowController.sortBy(_:)), identifier: "SB.none"))
        view.addItem(sortMenuItem)

        let directionMenuItem = NSMenuItem(title: title("Sort Direction"), action: nil, keyEquivalent: "")
        let direction = NSMenu(title: title("Sort Direction"))
        directionMenuItem.submenu = direction
        direction.addItem(item(title("Ascending"), action: #selector(ShellWindowController.sortDirectionBy(_:)), identifier: "Ascending"))
        direction.addItem(item(title("Descending"), action: #selector(ShellWindowController.sortDirectionBy(_:)), identifier: "Descending"))
        view.addItem(directionMenuItem)

        view.addItem(.separator())
        view.addItem(item(title("Always On Top"), action: #selector(AppDelegate.toggleAlwaysOnTop(_:)), key: "t", modifiers: [.command, .option]))
        view.addItem(item(title("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))

        // MARK: Window menu

        let windowMenuItem = NSMenuItem()
        main.addItem(windowMenuItem)
        let window = NSMenu(title: title("Window"))
        windowMenuItem.submenu = window

        window.addItem(item(title("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item(title("Zoom"), action: #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(title("Main Window"), action: #selector(AppDelegate.openMainWindow(_:)), key: "0", modifiers: [.command, .option]))
        window.addItem(item(title("Active Window"), action: #selector(AppDelegate.activeWindow(_:)), key: "m", modifiers: [.command, .option]))
        window.addItem(.separator())
        window.addItem(item(title("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:))))

        NSApp.mainMenu = main
    }
}
