import Cocoa
import KeyboardShortcuts
import Sparkle
import os.log

// The SwiftPM build has no storyboard, and `@main` on an NSApplicationDelegate
// does not instantiate the delegate in that setup (verified by probe). The
// programmatic entry lives in main.swift, which wires the delegate by hand.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var mainWindowController: MainWindowController?
    /// The SwiftUI main window, opened instead of the storyboard one only
    /// under `-MiaoYanShell YES`.
    var shellWindowController: NSWindowController?
    /// The search palette, built with the shell window.
    var paletteWindow: ShellPaletteWindow?
    var prefsWindowController: PrefsWindowController?
    var aboutWindowController: AboutWindowController?
    var openSourceLicensesWindowController: OpenSourceLicensesWindowController?
    public var urls: [URL]?
    public var searchQuery: String?
    public var newName: String?
    public var newContent: String?
    /// A miaoyan://goto that arrived before the window, as the CLI's
    /// `miao open` sends when it launches the app.
    public var pendingGoto: URL?
    let appContext = AppContext.shared
    private var updaterController: SPUStandardUpdaterController?

    private func resolveViewController() -> ViewController? {
        if let cached = appContext.viewController {
            return cached
        }

        let candidates: [NSViewController?] = [
            mainWindowController?.window?.contentViewController,
            mainWindowController?.contentViewController,
            NSApp.mainWindow?.contentViewController,
            NSApp.keyWindow?.contentViewController,
        ]

        for candidate in candidates {
            if let vc = candidate as? ViewController {
                appContext.bind(viewController: vc)
                return vc
            }
        }

        return nil
    }
    var appTitle: String {
        if let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            return display
        }
        return Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String ?? "MiaoYan"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        migratePreferences()
        UserDefaultsManagement.migrateFontDefaultsIfNeeded()
        // The bundled JinBuTi face is registered here, before the first row
        // resolves its font, and the interface face moves to it once.
        FontConfiguration.migrateInterfaceFontToJinBuTi()
        UserDefaultsManagement.clearSingleMode()
        let storage = appContext.storage
        storage.loadProjects()
        storage.loadDocuments {}
    }

    /// The preferences domain from before the bundle id was lowercased. On a
    /// case-insensitive volume it is the same file as `com.tw93.miaoyan`'s,
    /// so a build with any other bundle id (`com.tw93.miaoyan.qa` for local
    /// tests) read the maintainer's real settings through it and copied them
    /// in on first launch, fonts and library location included.
    static let legacyPreferencesDomain = "com.tw93.MiaoYan"
    static let shippedBundleIdentifier = "com.tw93.miaoyan"
    static let legacyMigrationKey = "HasMigratedFromOldSuite"

    private func migratePreferences() {
        Self.migrateLegacyPreferences(
            into: UserDefaults.standard,
            legacy: UserDefaults.standard.persistentDomain(forName: Self.legacyPreferencesDomain),
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Copies keys the standard domain lacks from the legacy domain, once, and
    /// only for the shipped bundle id. `legacy` is that domain's own keys, not
    /// a suite's `dictionaryRepresentation()`, which also carries the global
    /// domain (AppleLanguages and the like).
    static func migrateLegacyPreferences(into standard: UserDefaults, legacy: [String: Any]?, bundleIdentifier: String?) {
        guard bundleIdentifier == shippedBundleIdentifier else { return }
        guard !standard.bool(forKey: legacyMigrationKey) else { return }
        for (key, value) in legacy ?? [:] where standard.object(forKey: key) == nil {
            standard.set(value, forKey: key)
        }
        standard.set(true, forKey: legacyMigrationKey)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // A swift-built binary does not inherit the LaunchServices activation
        // a bundled app gets; without this the process runs without a dock
        // presence or key focus (the skymap-mac packaging lesson).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Sparkle needs a feed in Info.plist; the SwiftPM build ships none
        // and skips the updater entirely.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil)
        }

        // The SwiftPM build has no storyboard menu; build one before the icon
        // pass so it decorates our items too.
        MainMenuBuilder.install()
        NSApp.mainMenu?.applyMenuIcons()

        NSApp.mainMenu?.update()

        configureSystemLogging()
        NSFontManager.shared.fontPanel(false)?.orderOut(self)

        if CommandLine.arguments.contains("--alert-probe") {
            runAlertLayoutProbe()
        }
        if CommandLine.arguments.contains("--palette-probe") {
            runPaletteProbe()
        }

        applyAppearance()

        // --start-preview boots into the rendered mode, so screenshots can
        // verify preview typography without pressing ⌘E (--alert-probe's
        // sibling scaffolding).
        if CommandLine.arguments.contains("--start-preview") {
            UserDefaultsManagement.preview = true
        }

        // The headless UI-script harness (scripts/ui_script.py): launch args
        // -SkyBookScript/-SkyBookShots plus a scratch -storageUrl.
        UIScript.startIfRequested()

        addGlobalKeyboardMonitor()
        if UserDefaultsManagement.storagePath == nil {
            requestStorageDirectory()
            return
        }
        // Option-Command-M brings the window forward unless someone set
        // another key; both windows need it, so it is set before either opens.
        if KeyboardShortcuts.getShortcut(for: .activateWindow) == nil {
            KeyboardShortcuts.setShortcut(.init(.m, modifiers: [.command, .option]), for: .activateWindow)
        }
        // The SwiftPM build always opens the SwiftUI shell; the storyboard
        // window below stays only for the main-branch Xcode project.
        if ShellWindowController.isRequested {
            let shell = ShellWindowController()
            shell.showWindow(nil)
            shellWindowController = shell
            paletteWindow = ShellPaletteWindow(model: shell.model)
            // A file double-clicked in Finder can arrive before the window.
            // So can a link that arrived before it.
            if let url = urls?.first {
                urls = nil
                shell.model.openSingle(url, siblingFiles: Self.siblingNoteFiles(of: url))
            } else if let query = searchQuery {
                searchQuery = nil
                shell.model.search(for: query)
            } else if newName != nil || newContent != nil {
                shell.model.createNote(name: newName ?? "", content: newContent ?? "")
                newName = nil
                newContent = nil
            } else if let goto = pendingGoto {
                pendingGoto = nil
                RouteMiaoYanGoto(goto)
            }
            return
        }
        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        guard let mainWC = storyboard.instantiateController(withIdentifier: "MainWindowController") as? MainWindowController else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = I18n.str("Critical Error")
            alert.informativeText = I18n.str("Failed to initialize main window. Please restart the application.")
            alert.addButton(withTitle: I18n.str("Quit"))
            alert.runModal()

            NSApplication.shared.terminate(nil)
            return
        }
        normalizeMainWindowFrame(mainWC.window)

        // Apply fade-in for first launch to match re-open behavior and hide initial blank state
        mainWC.window?.alphaValue = 0
        mainWC.window?.makeKeyAndOrderFront(nil)

        mainWindowController = mainWC
        appContext.bind(viewController: mainWC.window?.contentViewController as? ViewController)
        normalizeMainWindowFrame(mainWC.window)
        DispatchQueue.main.async { [weak self, weak window = mainWC.window] in
            self?.normalizeMainWindowFrame(window)
        }

        mainWC.applyMiaoYanAppearance()

        // Failsafe: Ensure window reveals after 3 seconds even if list loading hangs or fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            mainWC.revealWindowWhenReady()
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppEnvironment.current.storage.deferUntilFolderMoveFinishes({
            sender.reply(toApplicationShouldTerminate: true)
        }) {
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        UserDefaultsManagement.clearSingleMode()
        if let vc = resolveViewController() {
            vc.persistCurrentViewState()
            // Capture the current editor buffer into the active note before
            // we drain the debounce queue, otherwise an in-flight keystroke
            // from the last 1.5s would never reach Note.content.
            // Only while the editor shows the note: in preview a ticked task is
            // saved to the note alone, and the hidden buffer would undo it.
            if let activeNote = EditTextView.note, vc.shouldUseEditorTextContent {
                vc.editArea.saveTextStorageContent(to: activeNote)
            }
            vc.storage.flushPendingSaves()
        } else if #available(macOS 14, *), let shell = shellWindowController as? ShellWindowController {
            shell.flushEdits()
        }
        try? FileManager.default.removeItem(at: HtmlManager.previewBundleURL())
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent("ThumbnailsBig")
        try? FileManager.default.removeItem(at: temporary)
    }

    static func trackError(_ error: Error, context: String) {
        #if DEBUG
            print("Error in \(context): \(error)")
        #endif
        Diagnostics.record(error: error, context: context)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            applyAppearance()
            mainWindowController?.makeNew()
            shellWindowController?.showWindow(nil)
        }
        return true
    }

    /// 视图菜单的外观快捷切换：写偏好、立即应用；shell 窗口的
    /// effectiveAppearance 观察器会把新观感传播给编辑器与预览。
    @objc func changeAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let type = AppearanceType(rawValue: raw) else { return }
        UserDefaultsManagement.appearanceType = type
        applyAppearance()
    }

    func applyAppearance() {
        if UserDefaultsManagement.appearanceType != .Custom {
            var targetAppearance: NSAppearance?
            var isDark = false

            switch UserDefaultsManagement.appearanceType {
            case .Dark:
                targetAppearance = NSAppearance(named: .darkAqua)
                isDark = true
            case .Light:
                targetAppearance = NSAppearance(named: .aqua)
                isDark = false
            case .System:
                targetAppearance = nil
                isDark = NSAppearance.current.isDark
            default:
                targetAppearance = nil
                isDark = NSAppearance.current.isDark
            }

            UserDataService.instance.isDark = isDark

            if NSApp.appearance != targetAppearance {
                NSApp.appearance = targetAppearance
            }
        }
    }

    private func restartApp() {
        AppDelegate.relaunchApp()
    }

    private func requestStorageDirectory() {
        var directoryURL: URL?
        if let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            directoryURL = URL(fileURLWithPath: path)
        }
        let panel = NSOpenPanel()
        panel.directoryURL = directoryURL
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = I18n.str("Please select default storage directory")
        panel.begin { result in
            if result == NSApplication.ModalResponse.OK {
                guard let url = panel.url else {
                    return
                }
                do {
                    try StorageLocationValidator.validateWritableDirectory(url)
                } catch {
                    self.showStorageDirectoryError(error) {
                        self.requestStorageDirectory()
                    }
                    return
                }
                // Bookmark first: storageUrl prefers it, so a failed bookmark
                // with a saved path would reopen the old folder.
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    UserDefaultsManagement.storageBookmark = bookmarkData
                } catch {
                    AppDelegate.trackError(error, context: "AppDelegate.requestStorageDirectory.bookmarkData")
                    self.showStorageDirectoryError(error) {
                        self.requestStorageDirectory()
                    }
                    return
                }
                UserDefaultsManagement.storagePath = url.path
                self.restartApp()
            } else {
                exit(EXIT_SUCCESS)
            }
        }
    }

    private func showStorageDirectoryError(_ error: Error, completion: @escaping () -> Void) {
        let message: String
        if let validationError = error as? StorageLocationValidationError {
            message = validationError.localizedMessage
        } else {
            message = error.localizedDescription
        }
        MiaoYanAlert.show(
            message: I18n.str("Could not use this folder"),
            informativeText: message,
            style: .warning,
            for: NSApp.keyWindow ?? NSApp.mainWindow
        ) { _ in
            completion()
        }
    }

    private func normalizeMainWindowFrame(_ window: NSWindow?) {
        guard let window else { return }

        let savedFrame = window.frame
        let isOffScreen = NSScreen.screens.allSatisfy { screen in
            !screen.visibleFrame.intersects(savedFrame)
        }
        let layoutMinimum = NSSize(width: 1100, height: 680)
        let isTooSmall = savedFrame.width < layoutMinimum.width || savedFrame.height < layoutMinimum.height

        window.minSize = NSSize(width: 960, height: 600)

        guard UserDefaultsManagement.isFirstLaunch || isTooSmall || isOffScreen else { return }

        let preferredSize = NSSize(width: 1280, height: 760)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let targetFrame: NSRect
        if let visibleFrame {
            let size = NSSize(
                width: min(preferredSize.width, max(900, visibleFrame.width - 40)),
                height: min(preferredSize.height, max(620, visibleFrame.height - 40))
            )
            targetFrame = NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        } else {
            targetFrame = NSRect(origin: savedFrame.origin, size: preferredSize)
        }

        window.setFrame(targetFrame, display: true)
    }

    // MARK: IBActions
    @IBAction func openMainWindow(_ sender: Any) {
        mainWindowController?.makeNew()
        shellWindowController?.showWindow(nil)
    }

    /// Quit, for both windows. Active Window's storyboard item targets a
    /// stand-in `ViewController`; the shell points it at the first responder,
    /// and the app delegate is the one link of that chain that is there
    /// whichever window is in front.
    @IBAction func quiteApp(_ sender: Any?) {
        guard UserDefaultsManagement.isSingleMode else {
            NSApp.terminate(sender)
            return
        }
        UserDefaultsManagement.clearSingleMode()
        UserDefaultsManagement.isFirstLaunch = true
        DispatchQueue.main.asyncAfter(deadline: .now() + UIDelay.short) {
            NSApp.terminate(nil)
        }
    }

    @IBAction func activeWindow(_ sender: Any?) {
        if #available(macOS 14, *), let shell = shellWindowController as? ShellWindowController {
            shell.toggleFrontmost()
        }
    }
    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }
    @IBAction func openPreferences(_ sender: Any?) {
        if prefsWindowController == nil {
            prefsWindowController = PrefsWindowController()
        }
        prefsWindowController?.show()
    }
    @IBAction func new(_ sender: Any?) {
        if #available(macOS 14, *), let shell = shellWindowController as? ShellWindowController {
            shell.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            shell.fileMenuNewNote(sender)
            return
        }
        mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        resolveViewController()?.fileMenuNewNote(self)
    }
    /// File ▸ New Note with the shell window closed: the item targets the
    /// first responder there, so with no window it reaches this delegate,
    /// which brings the window back first as the storyboard window does.
    @IBAction func fileMenuNewNote(_ sender: Any?) { new(sender) }
    @IBAction func searchAndCreate(_ sender: Any?) {
        if #available(macOS 14, *), let shell = shellWindowController as? ShellWindowController {
            shell.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            shell.searchNotes(sender)
            return
        }
        mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        guard let vc = resolveViewController() else { return }
        DispatchQueue.main.async {
            vc.search.window?.makeFirstResponder(vc.search)
        }
    }
    /// The iPhone and iPad app's App Store page: a menu item and a line in
    /// About, nothing that appears on its own.
    static let mobileAppURL = URL(string: "https://apps.apple.com/app/miaoyan/id6759252269")

    @IBAction func openMobileApp(_ sender: Any?) {
        guard let url = AppDelegate.mobileAppURL else { return }
        NSWorkspace.shared.open(url)
    }

    @IBAction func showAboutWindow(_ sender: AnyObject) {
        // SwiftPM build: no storyboard About scene; use the standard panel.
        NSApp.orderFrontStandardAboutPanel(options: [:])
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func showOpenSourceLicenses(_ sender: Any?) {
        let controller = openSourceLicensesWindowController ?? OpenSourceLicensesWindowController()
        openSourceLicensesWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(controller)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == NSEvent.EventType.leftMouseDown {
            mainWindowController?.makeNew()
        }
    }

    @IBAction func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        toggleAlwaysOnTop()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.identifier?.rawValue == "viewMenu.alwaysOnTop" {
            menuItem.state = UserDefaultsManagement.alwaysOnTop ? .on : .off
            return true
        }
        // Only validate menu items that AppDelegate can actually handle
        if let action = menuItem.action {
            return self.responds(to: action)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    // MARK: - Logging Configuration
    private func configureSystemLogging() {
        setenv("OS_ACTIVITY_MODE", "disable", 1)
        setenv("MTL_HUD_ENABLED", "0", 1)
        setenv("MTL_DEBUG_LAYER", "0", 1)
        setenv("MTL_SHADER_VALIDATION", "0", 1)
        setenv("MTL_CAPTURE_ENABLED", "0", 1)
        setenv("METAL_PERFORMANCE_SHADERS_LOGGING", "0", 1)
        configureURLCache()
    }

    private func configureURLCache() {
        let memoryCapacity = 50 * 1024 * 1024  // 50MB
        let diskCapacity = 0  // Disable disk cache to prevent I/O errors
        let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: nil)
        URLCache.shared = cache
    }

    // MARK: - Always On Top Management
    private func toggleAlwaysOnTop() {
        let newValue = !UserDefaultsManagement.alwaysOnTop
        UserDefaultsManagement.alwaysOnTop = newValue

        NotificationCenter.default.post(name: .alwaysOnTopChanged, object: nil)

        let message = newValue ? I18n.str("Window stays on top") : I18n.str("Window normal mode")
        if let vc = resolveViewController() {
            vc.toast(message: message)
        } else if #available(macOS 14, *), let shell = shellWindowController as? ShellWindowController {
            shell.model.host?.toast(message: message)
        }
    }

    private func addGlobalKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()

            if event.keyCode == 17 || key == "t",  // kVK_ANSI_T
                flags == [.command, .shift]
            {
                if let vc = self.resolveViewController() {
                    vc.pin(vc.notesTableView.selectedRowIndexes)
                    return nil
                }
                if #available(macOS 14, *), let shell = self.shellWindowController as? ShellWindowController,
                    !shell.model.isPresenting, let note = shell.model.selectedNote
                {
                    shell.model.togglePin(note)
                    return nil
                }
            }

            // The presentation and PPT entries were retired with the merged
            // navigation column; their code paths stay for the storyboard
            // window on main.

            return event
        }
    }
}

// MARK: - Alert layout probe (temporary scaffolding)

extension AppDelegate {
    /// Presents the real new-folder alert on the real main window and dumps
    /// the sheet's settled geometry at timed points, for layout surgery work.
    /// Launch with `--alert-probe`; the sheet stays up for eyeballing.
    func runAlertLayoutProbe() {
        FileHandle.standardError.write("[probe] armed\n".data(using: .utf8)!)
        func dump(_ tag: String) {
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
                let content = window.contentView
            else {
                FileHandle.standardError.write("[probe] \(tag): no window\n".data(using: .utf8)!)
                return
            }
            FileHandle.standardError.write(
                ("[probe] \(tag) window=\(window.frame) sheet=\(window.attachedSheet?.frame ?? .zero)\n")
                    .data(using: .utf8)!)
            if let sheet = window.attachedSheet, let sheetContent = sheet.contentView {
                FileHandle.standardError.write(
                    ("[probe] \(tag) sheetContent=\(sheetContent.frame)\n").data(using: .utf8)!)
                for view in sheetContent.subviews {
                    FileHandle.standardError.write(
                        ("[probe]   \(String(describing: type(of: view))) frame=\(view.frame) hidden=\(view.isHidden)\n")
                            .data(using: .utf8)!)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            FileHandle.standardError.write(
                ("[probe] fire windows=\(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) main=\($0.isMainWindow) key=\($0.isKeyWindow)" })\n")
                    .data(using: .utf8)!)
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            field.focusRingType = .none
            field.placeholderString = "文件夹名称"
            let alert = MiaoYanAlert.make(
                message: "新建文件夹", style: .informational, buttons: ["添加", "取消"])
            alert.accessoryView = field
            MiaoYanAlert.style(alert)
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
            else {
                FileHandle.standardError.write("[probe] no host window\n".data(using: .utf8)!)
                return
            }
            alert.beginSheetModal(for: window, completionHandler: { _ in })
            MiaoYanAlert.arrangeIconBesideTitle(alert)
            dump("t+0")
            for delay in [0.05, 0.15, 0.4, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { dump("t+\(delay)") }
            }
        }
    }
}


// MARK: - Palette probe (temporary scaffolding)

extension AppDelegate {
    /// Opens the search palette with a sample query and snapshots the panel
    /// off-screen (cacheDisplay does not need a lit display), for layout
    /// eyeballing while the console is locked. Launch with `--palette-probe`.
    private static func findField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        for child in view.subviews {
            if let found = findField(in: child) { return found }
        }
        return nil
    }

    func runPaletteProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.paletteWindow?.model.openPalette(query: "妙言")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }),
                    let content = panel.contentView
                else {
                    FileHandle.standardError.write("[palprobe] no visible panel\n".data(using: .utf8)!)
                    return
                }
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: rep)
                let url = URL(fileURLWithPath: "/tmp/palette-probe.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                FileHandle.standardError.write("[palprobe] wrote \(url.path)\n".data(using: .utf8)!)
                // Key-status proof: the panel becomes key and the field
                // accepts an insert.
                panel.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let keyed = panel.isKeyWindow
                    if let field = Self.findField(in: panel.contentView) {
                        field.insertText("X")
                    }
                    FileHandle.standardError.write(
                        ("[palprobe] keyed=\(keyed) queryAfter=\(self.paletteWindow?.model.paletteQuery ?? "?")\n")
                            .data(using: .utf8)!)
                    self.paletteWindow?.model.closePalette()
                }
            }
        }
    }
}
