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
struct SkyBookApp {
    static func main() async {
        // One-time defaults migration: the SkyBook rebrand changed the bundle
        // identifier, and the user's library pointer (storageUrl) lives in
        // the old SkymapText domain. Carry the whole domain over once.
        let newDomain = Bundle.main.bundleIdentifier ?? "local.skybook"
        if UserDefaults.standard.persistentDomain(forName: newDomain)?["storageUrl"] == nil,
            let old = UserDefaults.standard.persistentDomain(forName: "local.skymaptext"),
            old["storageUrl"] != nil
        {
            var migrated = old
            // The shell is the only window now: a stored opt-out from the
            // storyboard era would hide it with no way back in.
            migrated.removeValue(forKey: "MiaoYanShell")
            UserDefaults.standard.setPersistentDomain(migrated, forName: newDomain)
        }

        // `--audit` runs the headless self-checks and exits with the verdict;
        // scripts/selfcheck.sh consumes it. The app never reaches its event
        // loop in this mode.
        if CommandLine.arguments.contains("--audit") {
            // The audit writes temp-folder storage paths and test state into
            // the defaults domain; snapshot the whole domain and restore it
            // after, so the user's real library pointer never moves.
            // Same fallback as the migration above: a bare `skybook --audit`
            // (selfcheck) has no bundle identifier; reading and restoring a
            // different domain than the writes touch left temp state behind.
            let domain = Bundle.main.bundleIdentifier ?? "local.skybook"
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
