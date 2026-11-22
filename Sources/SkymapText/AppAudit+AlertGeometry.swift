import AppKit
import SkyBook

/// The input sheets keep the bird and the title on one row: after style()
/// the sheet reclaims the title band and the title frame sits beside the
/// bird, centred to it. Probed on macOS 26: the sheet attach layout settles
/// synchronously inside beginSheetModal and no later pass re-runs, so the
/// runloop-turn-later surgery sticks.
@MainActor
func alertSheetGeometry(_ ctx: AuditContext) async throws {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    field.placeholderString = "文件夹名称"
    let alert = MiaoYanAlert.make(
        message: "新建文件夹", style: .informational, buttons: ["添加", "取消"])
    alert.accessoryView = field
    MiaoYanAlert.style(alert)
    alert.window.orderFrontRegardless()
    let before = alert.window.frame.height
    // The surgery is synchronous now: no runloop turn, no stacked frame.
    MiaoYanAlert.arrangeIconBesideTitle(alert)
    guard let content = alert.window.contentView else {
        throw AuditFailure(message: "alert content view missing")
    }
    try expect(alert.window.frame.height <= before - 32, "the surgery reclaims the title band in the same tick")
    guard
        let icon = content.subviews.first(where: { String(describing: type(of: $0)).contains("ImageView") })
    else {
        throw AuditFailure(message: "bird image view missing")
    }
    guard
        let title = content.subviews.first(where: {
            ($0 as? NSTextField)?.stringValue == alert.messageText && $0.frame.width > 4
        })
    else {
        throw AuditFailure(message: "title field missing")
    }
    try expect(title.frame.minX > icon.frame.maxX, "the title sits right of the bird")
    try expect(abs(title.frame.midY - icon.frame.midY) <= 1, "title and bird share a centre line")
    // The input row keeps its slot: the surgery only reclaims the title band.
    // accessoryView.frame is the field inside AppKit's wrapping container;
    // the container is the row the surgery must leave in place.
    let accessoryRow = alert.accessoryView?.superview
    try expect(
        accessoryRow == nil || abs(accessoryRow!.frame.maxY - 86) < 0.5,
        "the input row stays above the buttons")
}
