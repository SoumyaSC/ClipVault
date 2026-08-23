import Foundation
import AppKit
import ApplicationServices

/// Quick Paste: restores a stored item to the pasteboard and synthesises ⌘V
/// into the previously frontmost application.
///
/// Requires the Accessibility permission (we only *send* keystrokes; ClipVault
/// never reads other apps' UI).
enum QuickPaster {

    /// Virtual key code for "V" (kVK_ANSI_V from Carbon Events.h); kept inline
    /// to avoid dragging Carbon into this file.
    private static let vKeyCode: CGKeyCode = 9

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the standard macOS permission prompt if not yet granted.
    @discardableResult
    static func promptForTrustIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemAccessibilityPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Posts Command+V key-down/key-up to the session. No-op without permission.
    static func paste() {
        guard isTrusted,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(40_000)  // give the target app time to register key-down
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }

    /// Activates the previous app, waits for it to become active, then pastes.
    static func activateAndPaste(previousApp: NSRunningApplication?) {
        if let previousApp, !previousApp.isTerminated {
            if #available(macOS 14.0, *) {
                previousApp.activate()
            } else {
                previousApp.activate(options: [])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                paste()
            }
        } else {
            paste()
        }
    }
}
