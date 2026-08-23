import AppKit
import SwiftUI

/// Standard titled window hosting the preferences UI.
///
/// The SwiftUI content decides the size and the window adopts it: a hardcoded
/// content rect that disagrees with the content leaves the form squeezed and
/// scrolling. Layout is forced to settle before the window is ever ordered in,
/// so nothing is composited from a half-established layout.
final class SettingsWindowController: NSWindowController {

    private let hosting = NSHostingView(rootView: SettingsView())

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 560, height: 470)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipVault Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false

        // Size to what SwiftUI actually asked for, *then* centre.
        let fitting = hosting.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            window.setContentSize(fitting)
        }
        hosting.layoutSubtreeIfNeeded()
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        // Settle layout before the window is composited for the first time.
        hosting.layoutSubtreeIfNeeded()
        super.showWindow(sender)
        hosting.displayIfNeeded()
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// Re-shown windows get a fresh layout pass too — a cached SwiftUI tree can
    /// otherwise be composited before AppKit reports the window on screen.
    func windowDidBecomeKey(_ notification: Notification) {
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }
}
