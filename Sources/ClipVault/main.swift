import AppKit
import ClipVaultCore

// ClipVault — menu bar clipboard manager.
// Accessory app: no Dock icon, no main window; everything lives in the status bar.

// The process starts (and stays) on the main thread; bridge into the UI actor
// explicitly so the app delegate's isolation is satisfied.
let appDelegate: AppDelegate = MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    return delegate
}

NSApplication.shared.run()
