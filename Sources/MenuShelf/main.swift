import AppKit

if CommandLine.arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.run() }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
