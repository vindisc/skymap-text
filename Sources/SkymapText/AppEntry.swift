import AppKit

// Programmatic entry point for the SwiftPM build. Without a storyboard,
// NSApplicationMain does not instantiate an NSApplicationDelegate (probed on
// Swift 6.3/CLT: applicationDidFinishLaunching never fired), so the delegate
// is wired by hand before the event loop starts.
//
// `@main` on a struct instead of top-level code in main.swift: a main.swift
// file makes the target impossible to import, and the --audit self-checks in
// AppAudit.swift run inside this module with full internal access.
@main
struct SkymapTextApp {
    static func main() async {
        // `--audit` runs the headless self-checks and exits with the verdict;
        // scripts/selfcheck.sh consumes it. The app never reaches its event
        // loop in this mode.
        if CommandLine.arguments.contains("--audit") {
            // AppAudit is @MainActor; the await hops there from wherever the
            // entry point starts.
            let code = await AppAudit.run()
            exit(code)
        }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated {
            AppDelegate()
        }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
