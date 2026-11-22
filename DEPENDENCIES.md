# MiaoYan Dependencies

This document is the source of truth for runtime dependencies. Keep the table
below aligned with `Package.swift` by hand, in the same commit. Removals
matter as much as additions.

## Swift Package Manager

On branch `spm` the app builds as a plain SwiftPM executable (`SkyBook`,
sources under `Sources/SkymapText/`) for macOS 14+ with Command Line Tools;
`Package.swift` is the only dependency declaration. The storyboard project on
`main` still declares its own package references, but nothing on this branch
builds it.

| Package                                                            | Constraint | Purpose                                                |
| ------------------------------------------------------------------ | ---------- | ------------------------------------------------------ |
| [Sparkle](https://github.com/sparkle-project/Sparkle)              | 2.8.0+     | macOS auto-update; idle without an `SUFeedURL`          |
| [Highlightr](https://github.com/raspu/Highlightr)                  | 2.3.0+     | Native syntax highlighting in `Helpers/NotesTextProcessor.swift` |
| [swift-cmark-gfm](https://github.com/stackotter/swift-cmark-gfm)   | 1.0.2+     | GitHub Flavored Markdown parsing (preview + export)    |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | vendored, patched | Shortcut registration; local package under `Packages/KeyboardShortcuts` |
| [Prettier](https://github.com/simonbs/Prettier.git)                | 0.2.1+     | Markdown formatting from the Format command                            |

## Conditional Compilation

- Sparkle is linked on the SwiftPM build but the generated Info.plist has no
  `SUFeedURL`/`SUPublicEDKey`, so the updater is never started. The Mac App
  Store story belongs to `main`/`MiaoYan-Pro`; no `#if !APPSTORE` gate exists
  here.

## Bundled Frontend Assets

MiaoYan renders previews inside a `WKWebView` that loads bundled HTML/CSS/JS
from `Resources/DownView.bundle/`. These are vendored, not pulled by SPM, so
they are documented in a separate manifest:

- See `Resources/DownView.bundle/js/vendor/MANIFEST.json` for the exact
  version, source URL, license and SHA-256 of each vendored `.min.js`.
- Update flow: replace the file, regenerate the manifest hash via
  `shasum -a 256 path/to/file.min.js`, bump the manifest entry, and commit.

## Open Source Licenses

`THIRD-PARTY-NOTICES.md` is bundled into the app and shown at MiaoYan > Open
Source Licenses. Adding, removing or bumping a Swift package or a vendored
preview file updates its entry there in the same commit, including copyright
lines and any library the file bundles (Mermaid carries DOMPurify and, in its
ELK layout, elkjs under EPL-2.0); `scripts/test_notices.py` fails when a
`MANIFEST.json` file or a `Package.resolved` version has no entry.

## Platform Requirements

- macOS host target: 12.0+ (Monterey)
- Swift toolchain: 6.0
- Xcode: 16.0+ (matches the build setting in `MiaoYan.xcodeproj`)

## Working with Dependencies

Add a new SPM dependency via Xcode (File > Add Package Dependencies...) and
add a row to the table above in the same commit (and a line to `Package.swift`
if you keep that reference list current).

Updating versions:

```bash
# Resolve latest within the declared constraints
xcodebuild -project MiaoYan.xcodeproj -scheme MiaoYan -resolvePackageDependencies

# Show the resolved dependency tree
swift package show-dependencies
```

Remove a dependency by deleting it from the Xcode project's package references
(and from `Package.swift`), then delete `Package.resolved` and re-resolve.

## History

- 2025: Migrated off CocoaPods. `Podfile` and `Podfile.lock` removed.
  `libcmark_gfm` replaced with `swift-cmark-gfm`. `SSZipArchive` import
  renamed to `ZipArchive`. AppCenter, Alamofire, SwiftyJSON, and MASShortcut
  were removed in this transition; if you find references to them in older
  documentation or commit messages, that is why.
