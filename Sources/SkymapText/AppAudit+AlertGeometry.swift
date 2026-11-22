import AppKit
import SkymapText

/// Dumps the new-folder alert's geometry: which view makes the sheet tall.
@MainActor
func alertSheetGeometry(_ ctx: AuditContext) async throws {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    field.placeholderString = "文件夹名称"
    let alert = MiaoYanAlert.make(
        message: "新建文件夹", style: .informational, buttons: ["添加", "取消"])
    alert.accessoryView = field
    MiaoYanAlert.style(alert)
    alert.layout()

    let window = alert.window
    FileHandle.standardError.write(
        ("[geom] window=\(window.frame.size) contentView=\(window.contentView?.frame.size ?? .zero)\n")
            .data(using: .utf8)!)
    if let icon = alert.icon {
        FileHandle.standardError.write(
            ("[geom] icon size=\(icon.size) reps=\(icon.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" })\n")
                .data(using: .utf8)!)
    }

    func dump(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        FileHandle.standardError.write(
            ("\(indent)\(String(describing: type(of: view))) frame=\(view.frame) hidden=\(view.isHidden)\n")
                .data(using: .utf8)!)
        guard depth < 3 else { return }
        for sub in view.subviews { dump(sub, depth: depth + 1) }
    }
    if let content = window.contentView {
        dump(content, depth: 0)
    }
}
