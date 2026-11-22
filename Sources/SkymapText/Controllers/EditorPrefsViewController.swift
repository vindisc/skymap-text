import Cocoa

@MainActor
final class EditorPrefsViewController: BasePrefsViewController {
    private var settings = EditorSettings()
    private var uploadDropdown: PrefsDropdown!
    private var lineBreakDropdown: PrefsDropdown!
    private var lineBreakRow: PrefsRowView!
    private var previewLocationDropdown: PrefsDropdown!
    private var previewWidthDropdown: PrefsDropdown!

    private static let previewWidths = ["600px", "800px", "1000px", "1200px", "1400px"]

    override func setupUI() {
        uploadDropdown = makeDropdown(action: #selector(uploadServiceChanged(_:)))
        uploadDropdown.addOption(I18n.str("None"), value: "None")
        for service in ["uPic", "PicGo", "Picsee", "PicList"] {
            uploadDropdown.addOption(service, value: service)
        }

        lineBreakDropdown = makeDropdown(action: #selector(lineBreakChanged(_:)))
        lineBreakDropdown.addOption(I18n.str("Every Newline"), value: "MiaoYan")
        lineBreakDropdown.addOption(I18n.str("GitHub Style"), value: "Github")

        previewLocationDropdown = makeDropdown(action: #selector(previewLocationChanged(_:)))
        previewLocationDropdown.addOption(I18n.str("Top"), value: "Begin")
        previewLocationDropdown.addOption(I18n.str("Current Position"), value: "Editing")

        previewWidthDropdown = makeDropdown(action: #selector(previewWidthChanged(_:)))
        for width in Self.previewWidths {
            previewWidthDropdown.addOption(width, value: width)
        }
        previewWidthDropdown.addOption(I18n.str("Full Width"), value: UserDefaultsManagement.FullWidthValue)

        lineBreakRow = PrefsRowView(title: I18n.str("Line Breaks"), detail: "", controls: [lineBreakDropdown])

        addSections([
            [
                // The default mode row went with the split mode: Command-E
                // toggles the editor's two states now.
                PrefsRowView(title: I18n.str("Image Upload"), detail: I18n.str("Send pasted images through an uploader app"), controls: [uploadDropdown]),
            ],
            [
                lineBreakRow,
                PrefsRowView(title: I18n.str("Open Preview At"), detail: I18n.str("Where the preview starts when you open it"), controls: [previewLocationDropdown]),
                PrefsRowView(title: I18n.str("Preview Width"), detail: I18n.str("How wide the text runs in the preview"), controls: [previewWidthDropdown]),
            ],
        ])
    }

    private func makeDropdown(action: Selector) -> PrefsDropdown {
        let dropdown = PrefsDropdown()
        dropdown.target = self
        dropdown.action = action
        return dropdown
    }

    override func setupValues() {
        uploadDropdown.selectOption { $0 as? String == UserDefaultsManagement.defaultPicUpload }
        lineBreakDropdown.selectOption { $0 as? String == settings.editorLineBreak }
        previewLocationDropdown.selectOption { $0 as? String == settings.previewLocation }
        previewWidthDropdown.selectOption { $0 as? String == settings.previewWidth }
        updateLineBreakDetail()
    }

    /// The detail says what the chosen value does, since the two names alone
    /// do not tell a single newline's fate.
    private func updateLineBreakDetail() {
        lineBreakRow.detail =
            settings.editorLineBreak == "Github"
            ? I18n.str("A new line in the preview needs a blank line")
            : I18n.str("Each newline starts a new line in the preview")
    }

    @objc private func lineBreakChanged(_ sender: PrefsDropdown) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        settings.editorLineBreak = raw
        updateLineBreakDetail()
        settings.applyChanges()
    }

    @objc private func previewLocationChanged(_ sender: PrefsDropdown) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        settings.previewLocation = raw
        settings.applyChanges()
    }

    @objc private func previewWidthChanged(_ sender: PrefsDropdown) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        settings.previewWidth = raw
        settings.applyChanges()
    }

    @objc private func uploadServiceChanged(_ sender: PrefsDropdown) {
        guard let service = sender.selectedItem?.representedObject as? String else { return }
        UserDefaultsManagement.defaultPicUpload = service
        guard service != "None" else { return }
        let hint = String(format: I18n.str("Install and set up %@ first"), service)
        if let vc = ViewController.shared() {
            vc.toastImageSet(name: service)
        } else if #available(macOS 14, *),
            let shell = (NSApp.delegate as? AppDelegate)?.shellWindowController as? ShellWindowController,
            let host = shell.model.host
        {
            host.toast(message: hint, style: .failure)
        } else {
            // No toast host yet (the shell window is still building): a plain
            // alert carries the hint instead of dropping it on the floor.
            MiaoYanAlert.show(message: hint, style: .warning)
        }
    }
}
