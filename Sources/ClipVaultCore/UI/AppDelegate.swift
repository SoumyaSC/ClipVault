import Foundation
import AppKit
import Combine

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var popoverController: PopoverController?
    private var settingsWindowController: SettingsWindowController?
    private var purgeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var context: AppContext { AppContext.shared }

    /// The app shell lives in a separate executable target; this is the only
    /// symbol it needs from the core module.
    public override init() {
        super.init()
    }

    /// Distributed notification used to wake an already-running instance when a
    /// second copy is launched (single-instance hand-off).
    private static let activateNotificationName =
        Notification.Name("app.clipvault.ClipVault.activate")

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Single-instance guard: hand off to the running copy and exit.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                Self.activateNotificationName, object: nil, deliverImmediately: true)
            NSApp.terminate(self)
            return
        }

        setupStatusItem()
        setupPopover()
        setupObservers()

        context.monitor.start()
        context.store.purgeExpiredImages()
        UpdateChecker.shared.start(settings: context.settings)
        if context.settings.hotKeyEnabled {
            context.hotKey.registerDefault { [weak self] in
                self?.togglePopover()
            }
        }

        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.context.store.purgeExpiredImages()
            }
        }

        // Render the README screenshots and quit. See Scripts/make_screenshots.sh.
        if let renderDir = ProcessInfo.processInfo.environment["CV_RENDER_DIR"], !renderDir.isEmpty {
            ScreenshotRenderer.renderAll(into: URL(fileURLWithPath: renderDir, isDirectory: true))
            NSApp.terminate(nil)
            return
        }

        // Screenshot/QA affordance: open a surface at launch without a human
        // clicking the status item. See Scripts/make_screenshots.sh.
        switch ProcessInfo.processInfo.environment["CV_OPEN_AT_LAUNCH"] {
        case "settings":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openSettings() }
        case "panel":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showPopover() }
        default:
            break
        }

        // First run: surface the panel automatically so the app is never invisible.
        if !context.settings.welcomeShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPopover()
            }
        }
    }

    /// Re-launching the app (Finder double-click, Spotlight, `open`) opens the
    /// panel — the reliable path when a crowded menu bar hides the status icon.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        context.monitor.stop()
        context.store.flush()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = NSImage(systemSymbolName: "doc.on.doc.fill",
                                   accessibilityDescription: "ClipVault")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.toolTip = "ClipVault — ⌘⇧V"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open ClipVault",
                              action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let quickPaste = NSMenuItem(title: "Quick Paste Last Item",
                                    action: #selector(quickPasteLast), keyEquivalent: "")
        quickPaste.target = self
        menu.addItem(quickPaste)

        if case .available(let release) = UpdateChecker.shared.state {
            menu.addItem(.separator())
            let update = NSMenuItem(title: "Update to \(release.version)…",
                                    action: #selector(openUpdatePage), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ClipVault", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)   // synchronously shows the menu
        statusItem?.menu = nil                  // restore click-to-popover behaviour
    }

    // MARK: - Popover

    private func setupPopover() {
        let controller = PopoverController()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = nil   // follow system appearance
        popoverController = controller
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            context.previousApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.becomeKey()
        popoverController?.focusSearch()
    }

    func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: - Settings window

    private func ensureSettingsWindow() -> SettingsWindowController {
        if let existing = settingsWindowController {
            return existing
        }
        let controller = SettingsWindowController()
        settingsWindowController = controller
        return controller
    }

    // MARK: - Observers

    private func setupObservers() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.activateNotificationName, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPopover() }
        }
        NotificationCenter.default.addObserver(forName: .cvTogglePopover, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePopover() }
        }
        NotificationCenter.default.addObserver(forName: .cvClosePopover, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        NotificationCenter.default.addObserver(forName: .cvOpenSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        NotificationCenter.default.addObserver(forName: .cvAccessibilityNeeded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showAccessibilityAlert() }
        }
    }

    // MARK: - Menu actions

    @objc private func openFromMenu() {
        togglePopover()
    }

    @objc private func quickPasteLast() {
        guard let last = context.store.items.first else { return }
        context.performQuickPaste(last)
    }

    @objc private func openUpdatePage() {
        guard case .available(let release) = UpdateChecker.shared.state else { return }
        NSWorkspace.shared.open(release.page)
    }

    @objc private func openSettings() {
        closePopover()
        let controller = ensureSettingsWindow()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLogin() {
        let newValue = !LoginItem.isEnabled
        guard LoginItem.setEnabled(newValue) else {
            showLoginFailureAlert()
            return
        }
        context.settings.launchAtLogin = newValue
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Quick Paste needs one permission"
        alert.informativeText = """
        ClipVault needs Accessibility access solely to press ⌘V for you when you choose Quick Paste. \
        It never reads what you type or any other app's content.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            QuickPaster.openSystemAccessibilityPane()
        }
    }

    private func showLoginFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t update Launch at Login"
        alert.informativeText = "Move ClipVault to /Applications and try again. If it still fails, re-add it manually in System Settings › General › Login Items."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
