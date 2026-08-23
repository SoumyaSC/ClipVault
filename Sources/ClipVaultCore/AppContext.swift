import Foundation
import Combine
import AppKit

extension Notification.Name {
    static let cvOpenSettings = Notification.Name("cv.openSettings")
    static let cvClosePopover = Notification.Name("cv.closePopover")
    static let cvAccessibilityNeeded = Notification.Name("cv.accessibilityNeeded")
}

/// Single dependency container. Everything user-facing flows through here.
@MainActor
final class AppContext {

    static let shared = AppContext()

    let settings: SettingsStore
    let store: ClipStore
    let monitor: ClipboardMonitor
    let feedback: FeedbackController
    let hotKey = HotKeyCenter()

    /// App that was frontmost right before the panel opened — the Quick Paste target.
    var previousApp: NSRunningApplication?

    /// Prevents App Nap from throttling the 0.25s pasteboard poll while the
    /// Mac is otherwise idle. Held for the process lifetime; the cost is a few
    /// wake-ups per second, which is exactly the point.
    private var activityToken: NSObjectProtocol?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        settings = .shared
        let settingsRef = settings
        store = ClipStore(configProvider: { settingsRef.historyConfig })
        feedback = FeedbackController(settings: settings)

        let storeRef = store
        monitor = ClipboardMonitor { capture in
            _ = storeRef.add(capture)
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Clipboard monitoring"
        )

        observeSettings()
    }

    private func observeSettings() {
        settings.$hotKeyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.hotKey.registerDefault {
                        NotificationCenter.default.post(name: .cvTogglePopover, object: nil)
                    }
                } else {
                    self.hotKey.unregister()
                }
            }
            .store(in: &cancellables)

        settings.$launchAtLogin
            .removeDuplicates()
            .sink { enabled in
                if enabled != LoginItem.isEnabled {
                    LoginItem.setEnabled(enabled)
                }
            }
            .store(in: &cancellables)

        settings.$dockIconEnabled
            .removeDuplicates()
            .sink { enabled in
                NSApp.setActivationPolicy(enabled ? .regular : .accessory)
            }
            .store(in: &cancellables)

        // Retention changes take effect immediately, not on next capture.
        settings.$maxItems
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.store.applyMaintenance() }
            .store(in: &cancellables)

        settings.$imageRetentionDays
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.store.applyMaintenance() }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Restores `item` to the clipboard. Returns success.
    @discardableResult
    func performCopy(_ item: ClipItem) -> Bool {
        guard store.copyToPasteboard(item.id) else { return false }
        monitor.suppressCurrentChange()
        feedback.playCopiedAffirmation()
        return true
    }

    /// Copy + paste straight into the previous app.
    func performQuickPaste(_ item: ClipItem) {
        guard QuickPaster.isTrusted else {
            NotificationCenter.default.post(name: .cvAccessibilityNeeded, object: nil)
            return
        }
        guard store.copyToPasteboard(item.id) else { return }
        monitor.suppressCurrentChange()
        feedback.playCopiedAffirmation()
        let target = previousApp
        NotificationCenter.default.post(name: .cvClosePopover, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            QuickPaster.activateAndPaste(previousApp: target)
        }
    }

    func requestAccessibilityPermission() {
        QuickPaster.promptForTrustIfNeeded()
    }
}

extension Notification.Name {
    static let cvTogglePopover = Notification.Name("cv.togglePopover")
}
