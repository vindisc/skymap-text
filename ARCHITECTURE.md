# MiaoYan Architecture

> **Branch note (`spm`):** this branch is a pure-SwiftPM app named
> **SkymapText** — one executable target under `Sources/SkymapText/`, the
> shell window is the whole app, there is no storyboard at runtime, and
> packaging is `scripts/make_app.sh` (see `AGENTS.md`). Everything below
> about the storyboard window, the three-column layout, MiaoYan-Pro and the
> App Store flow describes the **`main` branch only**.

## Top-Level Map

```
.
├── Sources/SkymapText/
│   ├── Business/    # Models and core domain logic (Storage, Note, Project, WikilinkIndex, ...)
│   ├── Controllers/ # AppDelegate, MainMenuBuilder, prefs windows, storyboard-era classes (dormant)
│   ├── Views/       # EditTextView, MPreviewView, storyboard-era views (dormant)
│   ├── Helpers/     # Highlighting, formatting, theming, diagnostics
│   ├── Extensions/  # Swift extensions on Foundation / AppKit types
│   ├── Shell/       # THE app: ShellWindowController / ShellModel / ShellRootView / ShellEditor
│   └── main.swift   # Programmatic NSApplication bootstrap (no storyboard)
├── Packages/        # MiaoYanCore (shared pure logic) + vendored KeyboardShortcuts
├── Resources/       # DownView.bundle (preview), Fonts, Localization, Images.xcassets
├── scripts/         # make_app.sh / run_app.sh / package_app.sh (+ main-branch helpers)
└── docs/            # incidents ledger, release notes (review-gate input)
```

## Process Model

A single macOS application process owns:

- One `NSApplication` (subclass-free; `AppDelegate` is the delegate).
- One `MainWindowController` (`Controllers/MainWindowController.swift`),
  which loads `Resources/Localization/Base.lproj/Main.storyboard`.
- One `ViewController` (`Controllers/ViewController.swift` + its `+` extensions),
  the host for the sidebar / notes list / editor / preview.
- One `WKWebView` instance per editor pane that loads
  `Resources/DownView.bundle/index.html` for live preview.

A SwiftUI main window under `Shell/` (`ShellWindowController`, `ShellModel`,
`ShellRootView`) opens instead of the storyboard window when the app is
launched with `-MiaoYanShell YES`. It hosts the same `EditTextView` and
`MPreviewView` and stays behind the flag until it reaches parity.

Logic the Mac app shares with the iPhone app (frontmatter, search matching,
note text decoding, list previews) lives in the local package
`Packages/MiaoYanCore`. The iPhone and iPad app and the App Store packaging
live in the private `tw93/MiaoYan-Pro`, which merges this repository's `main`;
this repository is the only Mac codebase.

## Singleton & Facade Inventory

Process-wide singletons (each "global" surface that holds state):

| Singleton                          | Where                                      | Role                                   |
| ---------------------------------- | ------------------------------------------ | -------------------------------------- |
| `Storage.sharedInstance()`         | `Business/Storage.swift`                   | Filesystem-backed note + project model |
| `WikilinkIndex.shared`             | `Business/WikilinkIndex.swift`             | `[[note]]` outgoing/incoming index     |
| `CloudSyncManager.shared`          | `Business/CloudSyncManager.swift`          | iCloud Drive coordination              |
| `NoteVersionManager.shared`        | `Business/NoteVersionManager.swift`        | Per-note version history               |
| `UserDataService.instance`         | `Helpers/UserDataService.swift`            | Cached user-level appearance state     |
| `AppContext.shared`                | `Business/Types.swift`                     | Holds storage + sessionState + view ref |
| `EditorStateManager.shared`        | `Helpers/UserDefaultsManagement.swift`     | Editor mode toggles                    |
| `ShortcutTemplateManager.shared`   | `Helpers/ShortcutTemplateManager.swift`    | Markdown insert templates              |
| `ToastManager.shared`              | `Views/Toast.swift`                        | Non-modal status messages              |

These are NOT going to be replaced wholesale; Storage is genuinely a single
filesystem mapping and that semantic is correct. New code should access them
through the facade:

```swift
// Preferred (new code)
let storage = AppEnvironment.current.storage

// Tolerated (existing code) but a SwiftLint warning under
// `no_direct_singleton_in_new_code`
let storage = Storage.sharedInstance()
```

`Business/AppEnvironment.swift` is a read-only facade over the existing
macOS services. It does not provide test overrides.

## Storyboard Anchors (Do Not Move Without Reading This First)

The following bindings live in `Main.storyboard` and depend on selectors /
identifiers existing on the named class. Renaming or moving any of these
breaks the UI at runtime without a compile-time error:

- `ViewController.swift` is the storyboard's `viewController` scene; **all**
  `@IBOutlet` and `@IBAction` declarations must stay on this class.
- `SidebarProjectView` is loaded as the storyboard's outline view subclass;
  its `awakeFromNib` is the construction entry point, not `init`.
- `NotesTableView` cell views have `NSUserInterfaceItemIdentifier("NoteCellView")`
  registered in the storyboard and dequeued in `Views/NotesTableView.swift`.
- `SidebarProjectView` cell views use identifier `"DataCell"` similarly
  (`Views/SidebarProjectView.swift`).
- The First Responder action chain is selector-based. `@IBAction` methods on
  `ViewController+Action.swift` must keep their exact ObjC selectors.

If you need to split `ViewController`, leave outlets and actions on the host
class and forward to coordinator objects from the action body.

## Editing Pipeline (Hot Path)

```
keystroke
  → EditTextView (NSTextView subclass; CustomTextStorage)
  → NSTextStorage.processEditing
  → NotesTextProcessor.checkPerformanceLevel
     ├─ short text:    full Markdown highlight via MarkdownRuleHighlighter
     └─ long/large:    simplified highlight (skips code block regex)
  → ViewController.textDidChange (the #543 `storageNote` owner guard runs here)
     ├─ debounced disk save:  Note.save(content:)
     └─ debounced preview:    MPreviewView.updateContent (adaptive 0.3/0.6/1.0s)
```

Performance ceilings live in `Helpers/NotesTextProcessor.swift`:

- > 1 MB total length OR > 64 KB in a single paragraph: simplified highlight, no code highlight.
- > 5000 lines: simplified, no code highlight.
- > 2000 lines: simplified, code highlight still on.

## Preview Pipeline

```
Note.content (NSMutableAttributedString)
  → swift-cmark-gfm → HTML string
     ↳ post-render transforms in renderMarkdownHTML (math <br> cleanup,
       GitHub Alerts blockquote → callout rewrite)
  → MPreviewView (WKWebView)
     ↳ loads Resources/DownView.bundle/index.html one-shot
     ↳ postReadyCallbacks fire when WKWebView didFinish navigation lands
     ↳ subsequent edits use incremental DOM mutation, not full reload
```

Bundled JS used by the preview is vendored under
`Resources/DownView.bundle/js/` and indexed in
`Resources/DownView.bundle/js/vendor/MANIFEST.json` (versions + SHA-256).

## Filesystem Conventions

- Note files: user-selected storage path (security-scoped bookmark in
  `UserDefaultsManagement.storageBookmark`).
- Note attachments: `i/` (inline images) and `files/` (other attachments)
  subdirectories at the note's level.
- Trash: notes go to the library's own `Trash` folder
  (`Storage.checkLibraryTrash`, `Storage.trashItem`); folders and images go to
  `Storage.systemTrashDestination` (the volume's system Trash, falling back to
  the library Trash).
- Symlinked directories: supported but indexed in a way that avoids recursion
  loops (`Business/Storage.swift::checkSub`).
- Version history: `Library/Application Support/com.tw93.miaoyan/Versions/<path-hash>/`
  managed by `NoteVersionManager`, keyed by the note's path and moved along
  on rename, folder move and Trash.
- Diagnostics log: `~/Library/Logs/MiaoYan/diagnostics.log` (ring buffer,
  50 lines, JSON per line). See `Helpers/Diagnostics.swift`.

## Release & Update Path

- Mac App Store builds come from the private `tw93/MiaoYan-Pro` after it
  merges this repository's `main`.
- Direct downloads: `bash scripts/build.sh` produces a zipped `.app`; when the
  maintainer's private `~/.config/miaoyan/build.sh` exists it runs instead. The
  Sparkle `appcast.xml` is updated by `scripts/release-ci/update_appcast.sh`
  (needs the Sparkle EdDSA private key).
- Version triplet (must stay aligned): git tag `Vx.y.z`, `MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`. CI rejects mismatches when a tag is pushed.

## Current Wiring Notes

- `Helpers/Diagnostics.swift` is in the app target, and
  `AppDelegate.trackError` records release diagnostics through it.
- `Business/AppEnvironment.swift` is in the app target and is the preferred
  facade for new singleton access.
- `Helpers/UIDelay.swift` is in the app target for semantic async delay names.
- `MiaoYanTests/` is wired into `MiaoYan.xcodeproj`, and CI runs the macOS unit
  test step together with the Debug app build.

## See Also

- `AGENTS.md` - agent-facing repo guide (commands, and the risk areas in `.claude/rules/`: storage, preview, editor, shell)
- `.claude/rules/swift.md` - project-level Swift conventions
- `~/.claude/CLAUDE.md` - global rules (writing style, commit policy, git safety)
