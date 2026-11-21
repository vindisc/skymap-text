# SkymapText Agent Guide (branch `spm`)

> This branch is a pure-SwiftPM restructure of MiaoYan's Mac app, rebranded
> **SkymapText**. It builds and runs **without Xcode** (Command Line Tools
> only). The storyboard project, the three-column window, the split /
> presentation / PPT modes and the upstream product story live on `main` and
> upstream — do not follow the main-branch docs when working here.

## Project

SkymapText is a lightweight Markdown notes app for macOS. The whole app is
one SwiftPM executable target (`SkymapText`, sources under
`Sources/SkymapText/`), window built programmatically:

- `Shell/` — the entire UI: `ShellWindowController` (AppKit
  `NSSplitViewController`, three panes), `ShellModel` (the one observable
  state object), `ShellRootView` (all SwiftUI views), `ShellEditor`
  (`ShellEditorController` owns the single `EditTextView`).
- `Business/` — Storage / Note / Project / WikilinkIndex / FontConfiguration.
- `Helpers/` — highlighting (`NotesTextProcessor`, `MarkdownRuleHighlighter`,
  `CustomTextStorage`), preview plumbing (`HtmlManager`), diagnostics.
- `Views/` — `EditTextView` (NSTextView editor), `MPreviewView`
  (WKWebView preview), prefs controllers' views.
- `Controllers/` — `AppDelegate` (@MainActor entry), `MainMenuBuilder`
  (programmatic NSMenu), prefs windows, `main.swift` sibling wiring.
- `Packages/MiaoYanCore/` — local package: pure-Foundation logic shared with
  the (upstream) iPhone app; frontmatter, note text, search, table editing.
- `Packages/KeyboardShortcuts/` — **vendored** sindresorhus/KeyboardShortcuts
  2.4.0, patched with `#if canImport(PreviewsMacros)` guards because plain
  `swift build` has no Xcode preview macros.
- `Resources/` — `DownView.bundle` (preview HTML/CSS/JS), Fonts (DingTalk
  JinBuTi is the interface face, registered per-process), Localization,
  Images.xcassets (flattened to loose files at packaging), `AppIcon.icns`.

## Commands

```bash
swift build -c debug|release        # compile (CLT only; no Xcode needed)
bash scripts/run_app.sh release     # rebuild + repackage + relaunch the app
bash scripts/make_app.sh release    # assemble .build/SkymapText.app (Info.plist,
                                    #   frameworks, resources, ad-hoc sign)
bash scripts/package_app.sh         # ditto-zip into dist/
bash scripts/selfcheck.sh           # build + audit scenarios + python gates
swiftlint lint --strict             # lint (config at .swiftlint.yml, when installed)
python3 scripts/check_incidents.py  # docs/incidents.md rows hold
python3 -m unittest discover -s scripts -p 'test_*.py'
```

## Testing

`swift test` is unavailable here (CLT ships no XCTest/Swift Testing runner).
The self-check instead is `Sources/SkymapText/AppAudit.swift`: nine headless
scenarios that build a temp-folder `ShellModel` and assert the audited
behaviors — outline refresh timing (note switch, cold-note async fill,
rendered-mode page load), merged nav rows, empty-folder hint, mixed arrow
navigation, the two-state editor toggle with persistence, the preview reuse
gate, and pending-rename commit on create. Run them through
`bash scripts/selfcheck.sh` (or `.build/debug/SkymapText --audit`); the exit
code carries the verdict. **Every bug fix on this branch lands with a
scenario in AppAudit.swift**, and selfcheck.sh runs after every change.
`MiaoYanTests/` and the XCTest suites are main-branch assets.

Full-app builds are the default verification for any Swift or packaging
change; `run_app.sh` is the dev loop (kills the old instance, rebuilds,
relaunches).

## Constraints and landmines

- **No Xcode on this machine.** `swift test` cannot run (CLT ships no
  XCTest); MiaoYanTests/ and Packages/MiaoYanCore/Tests are main-branch
  assets. Local verification = the commands above plus hand-testing the
  checklist in each task.
- **main.swift wires the delegate by hand.** Without a storyboard,
  `NSApplicationMain` never instantiates an `@main NSApplicationDelegate`
  (probed: `applicationDidFinishLaunching` never fired) — do not reintroduce
  `@main` on AppDelegate.
- **The buffer is sacrosanct.** Files are plain UTF-8; every renderer
  (preview, export, search, checkbox toggles) reads `storage.string` /
  `note.content.string`. Never mutate buffer characters for paint purposes.
- **The storyboard ships as an inert resource.** `Main.strings` still feeds
  menu-title localization (`MainMenuBuilder.title()`); the storyboard
  classes compile but are unreachable in the default shell path.
- **Assets are flattened at packaging.** `make_app.sh` copies imagesets as
  loose files (no `actool` without Xcode — colors fall back to system
  equivalents), drops `InfoPlist.strings` (it would rebrand the display
  name), and ships `THIRD-PARTY-NOTICES.md` for the licenses window.
- **`VERSION`** (root) drives `CFBundleShortVersionString` via
  `make_app.sh`; bundle id is `local.skymaptext`, so defaults never collide
  with the installed MiaoYan.app.
- **KeyboardShortcuts.Name** extension lives in legacy
  `Controllers/ViewController.swift:7` — relocate it before deleting that
  file.

## Legacy stack (main-only)

`MiaoYan.xcodeproj`, root `Info.plist`/entitlements, the storyboard window
classes (`MainWindowController`, `ViewController*`, `NotesTableView`,
`Sidebar*`, `EditorSplitView`, …), `scripts/build.sh`,
`scripts/add_tests_target.rb`, `scripts/release-ci/`, `MiaoYanTests/`,
`.github/workflows/ci.yml` and the `MiaoYan-Pro` App Store story are the
**main branch's** flow. They compile on `spm` (dormant behind
`defaults write MiaoYanShell NO`) but are not built, tested or packaged
here. Shell-reachable dead selectors (`togglePresentation`,
`toggleMagicPPT`, `toggleTOC`) stay for that stack.
