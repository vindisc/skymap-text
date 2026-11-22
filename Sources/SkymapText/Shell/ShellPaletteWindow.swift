import AppKit
import Carbon.HIToolbox
import SwiftUI
import MiaoYanCore

/// A borderless panel that takes key status for its text field.
@MainActor
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The search palette: a centred panel over the shell window, Spotlight
/// style. A separate panel, not an overlay in the split layout, so the
/// folder tree never gives way to results and the panel outlives column
/// toggles. The model's palette pipeline does the searching; this window is
/// the field, the rows and the keys.
@MainActor
final class ShellPaletteWindow {
    private let panel: NSPanel
    let model: ShellModel
    private var thermal: Any?

    init(model: ShellModel) {
        self.model = model
        // Borderless: a .titled panel draws its window frame around the
        // SwiftUI card's transparent padding, and the card carries its own
        // shadow anyway. Keyable: a borderless window cannot become key by
        // default, and the query field must take typing.
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = SelfDelegate(model: model)

        let hosting = NSHostingView(rootView: ShellPaletteSheet(model: model, onClose: { [weak self] in
            self?.model.closePalette()
        }))
        panel.contentView = hosting
        hosting.sizingOptions = [.preferredContentSize]
        observeModel()
    }

    /// The model's flag is the one source of truth: every entry point (the
    /// menu, typing in the nav column, a skybook://find route, openByTitle's
    /// multi-match fallback) only touches the model, and the panel follows.
    private func observeModel() {
        let open = withObservationTracking {
            model.isPaletteOpen
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
        guard open != (panel.isVisible) else { return }
        if open {
            positionOverShell()
            panel.orderFrontRegardless()
            if let shell = panel.parent ?? NSApp.mainWindow {
                shell.addChildWindow(panel, ordered: .above)
            }
        } else {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// Centres the panel over the shell window, a little above the middle.
    private func positionOverShell() {
        guard let shell = NSApp.mainWindow else { return }
        let shellFrame = shell.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: shellFrame.midX - size.width / 2,
            y: shellFrame.midY - size.height / 2 + 60))
    }

    /// Panel closed by clicking away: the model flag follows.
    private final class SelfDelegate: NSObject, NSWindowDelegate {
        let model: ShellModel
        init(model: ShellModel) { self.model = model }

        func windowWillClose(_ notification: Notification) {
            model.closePalette()
        }

        func windowDidBecomeKey(_ notification: Notification) {}

    }
}

/// The palette's surface: the query field, the result rows and the key
/// hints. Keys are AppKit here, not SwiftUI's onKeyPress — the field's
/// first-responder chain delivers them through performKeyEquivalent, and the
/// panel's field editor needs the arrows while it holds the text.
@available(macOS 14, *)
struct ShellPaletteSheet: View {
    @Bindable var model: ShellModel
    let onClose: () -> Void
    @FocusState private var fieldFocused: Bool
    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SwiftUI.Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ShellStyle.tertiaryText)
                TextField(I18n.str("Search Notes"), text: Bindable(model).paletteQuery)
                    .textFieldStyle(.plain)
                    .font(ShellStyle.interface(15))
                    .focused($fieldFocused)
                    .onSubmit { model.paletteCommit() }
                if !model.paletteQuery.isEmpty {
                    SwiftUI.Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ShellStyle.tertiaryText)
                        .contentShape(Rectangle())
                        .onTapGesture { model.paletteQuery = "" }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ShellStyle.hairline.frame(height: 1)

            paletteRows

            HStack(spacing: 14) {
                hint(I18n.str("↑↓ Browse"), "arrow.up.arrow.down")
                hint(I18n.str("⏎ Open"), "return")
                hint(I18n.str("⌘⏎ New Note"), "square.and.pencil")
                hint(I18n.str("esc Close"), "escape")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ShellStyle.background)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ShellStyle.hairline, lineWidth: 1)
        )
        .padding(24)
        .opacity(appear ? 1 : 0)
        .scaleEffect(appear ? 1 : 0.97, anchor: .top)
        .onAppear {
            fieldFocused = true
            withAnimation(.easeOut(duration: 0.15)) { appear = true }
        }
        .background(KeyCatcher(model: model, onClose: onClose))
    }

    @ViewBuilder private var paletteRows: some View {
        if model.paletteResults.isEmpty {
            VStack(spacing: 6) {
                Text(I18n.str(model.paletteQuery.isEmpty ? "Type to search, ⌘⏎ to create" : "No matches"))
                    .font(ShellStyle.interface(13))
                    .foregroundStyle(ShellStyle.tertiaryText)
                    .padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.paletteResults.enumerated()), id: \.element.id) { index, result in
                            paletteRow(result, index: index)
                                .id(result.url)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .onChange(of: model.paletteSelected) { _, selected in
                    guard let result = model.paletteResults[safe: selected] else { return }
                    proxy.scrollTo(result.url, anchor: .center)
                }
            }
        }
    }

    private func paletteRow(_ result: ShellModel.PaletteResult, index: Int) -> some View {
        let isSelected = index == model.paletteSelected
        let title = Text(result.title)
            .font(ShellStyle.interface(13, weight: isSelected ? ShellStyle.titleWeight : .regular))
            .foregroundStyle(ShellStyle.text)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    title
                    title.lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if result.snippet == nil {
                    // A title hit: rank speaks through the badge.
                    Text(I18n.str("Title"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ShellStyle.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ShellStyle.field))
                }
            }
            if let snippet = result.snippet {
                Text(snippet)
                    .font(ShellStyle.interface(11))
                    .foregroundStyle(ShellStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !result.folder.isEmpty {
                Text(result.folder)
                    .font(ShellStyle.interface(10))
                    .foregroundStyle(ShellStyle.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Metrics.selectionCornerRadius, style: .continuous)
                    .fill(ShellStyle.sidebarSelection)
                    .padding(.horizontal, 8)
            }
        }
        .onTapGesture {
            model.paletteSelected = index
            model.paletteCommit()
        }
        .onHover { inside in
            // Hover picks the row, like a pointer does everywhere else.
            if inside { model.paletteSelected = index }
        }
        .id(result.url)
    }

    private func hint(_ label: String, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            SwiftUI.Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(ShellStyle.tertiaryText)
            Text(label)
                .font(ShellStyle.interface(10))
                .foregroundStyle(ShellStyle.tertiaryText)
        }
    }
}

/// Arrows, Return, ⌘Return and Esc while the palette's field holds the keys.
/// The field editor's keyDown lands here through the responder chain.
@available(macOS 14, *)
private struct KeyCatcher: NSViewRepresentable {
    let model: ShellModel
    let onClose: () -> Void

    final class CoordinatingView: NSView {
        var onKey: (NSEvent) -> Bool?

        init(onKey: @escaping (NSEvent) -> Bool?) {
            self.onKey = onKey
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            onKey(event) ?? false
        }
    }

    func makeNSView(context: Context) -> CoordinatingView {
        CoordinatingView { [model, onClose] event in
            let key = Int(event.keyCode)
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            switch key {
            case kVK_UpArrow where flags.isEmpty:
                model.paletteMove(-1)
                return true
            case kVK_DownArrow where flags.isEmpty:
                model.paletteMove(1)
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                model.paletteCommit(create: flags == [.command])
                return true
            case kVK_Escape:
                onClose()
                return true
            default:
                return nil
            }
        }
    }

    func updateNSView(_ view: CoordinatingView, context: Context) {}
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
