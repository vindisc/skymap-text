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
            // The audit writes temp-folder storage paths and test state into
            // the defaults domain; snapshot the whole domain and restore it
            // after, so the user's real library pointer never moves.
            let domain = Bundle.main.bundleIdentifier ?? "local.skymaptext"
            let snapshot = UserDefaults.standard.persistentDomain(forName: domain)
            let code = await AppAudit.run()
            if let snapshot {
                UserDefaults.standard.setPersistentDomain(snapshot, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
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
