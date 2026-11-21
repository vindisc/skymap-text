import Cocoa

/// Centralized font configuration for the app
/// All default fonts are defined here for easy maintenance
@MainActor
enum FontConfiguration {
    /// The default is the system pairing every Mac has: SF for Latin and the
    /// system's CJK face for the user's languages (PingFang for Chinese,
    /// Hiragino for Japanese). It is stored as PingFang's PostScript name,
    /// which `textFont(named:size:)` and `FontCatalog.fontStack` read as "not
    /// chosen" and set with the system face. A stored face that is not
    /// installed renders the same way and is never rewritten, so anyone who
    /// installed TsangerJinKai02 keeps it.
    static let fallbackFont = "PingFangSC-Regular"
    static let defaultEditorFont = fallbackFont

    /// Default interface font name
    static let defaultInterfaceFont = fallbackFont

    /// Default preview font name
    static let defaultPreviewFont = fallbackFont

    /// Stored as the code font when code blocks use the text font, the editor
    /// font in the editor and the preview font in the preview. It names no
    /// installed face, so it is checked before any font lookup.
    static let followTextFont = "FollowText"

    /// Default code font name
    static let defaultCodeFont = followTextFont

    /// The DingTalk JinBuTi face bundled with the app: the interface's own
    /// face, registered per-process before the first row renders. Single
    /// weight, so the heading synthesis in `ShellBoldText` applies. Free for
    /// commercial use under DingTalk's font license
    /// (Resources/Fonts/DingTalk JinBuTi License.txt).
    static let dingTalkJinBuTi = "DingTalk-JinBuTi"
    private static let dingTalkJinBuTiFile = "DingTalk JinBuTi.ttf"

    /// Registered once per process; `interfaceFont` and the one-time
    /// migration both force it.
    private static let bundledFontsRegistered: Bool = {
        if NSFont(name: dingTalkJinBuTi, size: 12) != nil { return true }
        let candidates: [URL] = [
            // The packaged app: Resources/Fonts next to the binary.
            Bundle.main.url(forResource: "DingTalk JinBuTi", withExtension: "ttf", subdirectory: "Fonts"),
            // Unpackaged `swift run` from the repo root.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Fonts/\(dingTalkJinBuTiFile)"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if NSFont(name: dingTalkJinBuTi, size: 12) != nil { return true }
        }
        return false
    }()

    static func registerBundledFonts() {
        _ = bundledFontsRegistered
    }

    /// One-time move of the interface face to the bundled JinBuTi, for
    /// sessions that still store the PingFang default. A face the user chose
    /// through the font panel is left alone; the editor and preview faces
    /// are the reader's own choice and stay as they are.
    static func migrateInterfaceFontToJinBuTi() {
        registerBundledFonts()
        let migrationKey = "interfaceFontJinBuTi_v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationKey)
        // UserDefaultsManagement.Constants is private; the key literal is
        // what its WindowFontName accessor writes.
        let stored = UserDefaults.standard.string(forKey: "windowFontName")
        if stored == nil || stored == fallbackFont {
            UserDefaultsManagement.windowFontName = dingTalkJinBuTi
        }
    }

    /// Returns the actual NSFont for editor use
    static func editorFont(size: CGFloat) -> NSFont {
        textFont(named: UserDefaultsManagement.fontName, size: size)
    }

    /// Returns the actual NSFont for interface use
    static func interfaceFont(size: CGFloat) -> NSFont {
        registerBundledFonts()
        return textFont(named: UserDefaultsManagement.windowFontName, size: size)
    }

    /// A stored text face, or the system face when the stored value is the
    /// default PingFang or names a face that is not installed. PingFang's own
    /// Latin is drawn for interface labels, wider than SF; the system face
    /// draws Latin itself and falls back to PingFang (or Hiragino for a
    /// Japanese-first user) for CJK, and its family resolves through
    /// `NSFontManager`, so the editor's bold and italic lookups keep working.
    static func textFont(named name: String, size: CGFloat) -> NSFont {
        let pingFang = NSFont(name: fallbackFont, size: size)?.familyName
        if let font = NSFont(name: name, size: size), font.familyName != pingFang {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// Returns the actual NSFont for code
    static func codeFont(size: CGFloat) -> NSFont {
        let fontName = UserDefaultsManagement.codeFontName
        return NSFont(name: fontName, size: size)
            ?? NSFont.userFixedPitchFont(ofSize: size)
            ?? NSFont.systemFont(ofSize: size)
    }
}
