import AppKit

// Programmatic entry point for the SwiftPM build. Without a storyboard,
// NSApplicationMain does not instantiate an NSApplicationDelegate (probed on
// Swift 6.3/CLT: applicationDidFinishLaunching never fired), so the delegate
// is wired by hand before the event loop starts.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated {
    AppDelegate()
}
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
