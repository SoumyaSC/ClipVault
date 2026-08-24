import AppKit
import SwiftUI

/// Renders the real UI to PNGs for the README, straight from the view
/// hierarchy — no window server, no screen recording permission, and it works
/// with the screen locked or over SSH.
///
/// These are renders of the shipping views, not mock-ups: what lands in
/// `docs/screenshots/` is what the app draws. Driven by `CV_RENDER_DIR`, which
/// only `Scripts/make_screenshots.sh` ever sets.
@MainActor
enum ScreenshotRenderer {

    /// The panel, in both appearances plus a mid-search state.
    ///
    /// Only the panel is rendered this way. The Settings window is deliberately
    /// absent: on macOS 26 its tab bar and switch fills are compositor-side
    /// materials that come out blank or grey in an offscreen bitmap, so
    /// `Scripts/make_screenshots.sh` captures that window through the window
    /// server instead. Shipping a render that misrepresents the UI would be
    /// worse than shipping no screenshot.
    static func renderAll(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        render(HistoryView(viewModel: HistoryViewModel()),
               size: panelSize,
               appearance: NSAppearance(named: .darkAqua),
               to: directory.appendingPathComponent("panel-dark.png"))

        render(HistoryView(viewModel: HistoryViewModel()),
               size: panelSize,
               appearance: NSAppearance(named: .aqua),
               to: directory.appendingPathComponent("panel-light.png"))

        render(HistoryView(viewModel: searchingViewModel()),
               size: panelSize,
               appearance: NSAppearance(named: .darkAqua),
               to: directory.appendingPathComponent("panel-search-dark.png"))
    }

    private static let panelSize = NSSize(width: 384, height: 560)

    /// The panel mid-search, so the README can show filtering rather than claim it.
    private static func searchingViewModel() -> HistoryViewModel {
        let model = HistoryViewModel()
        model.query = "clips"
        return model
    }

    private static func render<Content: View>(_ view: Content,
                                              size: NSSize,
                                              appearance: NSAppearance?,
                                              to url: URL) {
        // `controlActiveState` is what SwiftUI consults for selection colour and
        // secondary text; a render process is never the *active* app, and the
        // inactive state greys all of that out.
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance

        // Off-screen and never ordered in, so nothing flashes on the user's
        // display. `AlwaysKeyWindow` supplies the one thing that would
        // otherwise be missing: controls drawn in their active state rather
        // than the greyed-out inactive one.
        let window = AlwaysKeyWindow(contentRect: NSRect(x: -10_000, y: -10_000,
                                                        width: size.width, height: size.height),
                                    styleMask: [.borderless],
                                    backing: .buffered,
                                    defer: false)
        window.appearance = appearance
        window.title = "ClipVault Settings"
        window.contentView = hosting

        // Let SwiftUI settle: one pass is not enough for a TabView switching to
        // a non-default tab, and thumbnails decode lazily on first display.
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))

        let target: NSView = hosting
        target.layoutSubtreeIfNeeded()
        target.displayIfNeeded()

        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            NSLog("ClipVault: could not allocate a bitmap for \(url.lastPathComponent)")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("ClipVault: could not encode \(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            NSLog("ClipVault: wrote \(url.lastPathComponent) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            NSLog("ClipVault: could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Claims key status so AppKit and SwiftUI draw switches, accents and
    /// selection in the state a user actually sees. A plain offscreen window
    /// never becomes key, and everything renders greyed out.
    private final class AlwaysKeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }
}
