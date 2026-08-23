import Foundation
import AppKit
import SwiftUI

/// Hosts the SwiftUI panel inside an NSPopover and owns keyboard handling.
/// A local `NSEvent` monitor intercepts navigation keys *before* SwiftUI so the
/// list behaves exactly like a native macOS picker (arrows, ↩, ⌘↩, ⌘1-9, ⌫).
final class PopoverController: NSViewController {

    let viewModel = HistoryViewModel()
    private var keyMonitor: Any?

    override func loadView() {
        let hosting = NSHostingView(rootView: HistoryView(viewModel: viewModel))
        hosting.frame = NSRect(x: 0, y: 0, width: 384, height: 560)
        view = hosting
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installKeyMonitor()
        viewModel.beginSession()
    }

    override func viewWillDisappear() {
        removeKeyMonitor()
        super.viewWillDisappear()
    }

    func focusSearch() {
        viewModel.focusSearchToken += 1
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.view.window === event.window else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Let ⌘W / ⌘Q and friends behave globally; we only steer bare keys.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53:  // esc
            NotificationCenter.default.post(name: .cvClosePopover, object: nil)
            return nil

        case 125 where flags.isEmpty:  // ↓
            viewModel.moveSelection(+1)
            return nil

        case 126 where flags.isEmpty:  // ↑
            viewModel.moveSelection(-1)
            return nil

        case 36:  // return
            if flags.contains(.command) {
                viewModel.quickPasteSelected()
            } else if flags.isEmpty {
                viewModel.copySelected()
            } else {
                return event
            }
            return nil

        case 51 where flags.contains(.command):  // ⌘⌫ delete selected
            viewModel.deleteSelected()
            return nil

        case 18, 19, 20, 21, 23, 22, 26, 28, 25:  // ⌘1…⌘9 jump-copy
            guard flags.contains(.command), !flags.contains(.shift), !flags.contains(.option) else {
                return event
            }
            let keyIndex: Int
            switch event.keyCode {
            case 18: keyIndex = 0
            case 19: keyIndex = 1
            case 20: keyIndex = 2
            case 21: keyIndex = 3
            case 23: keyIndex = 4
            case 22: keyIndex = 5
            case 26: keyIndex = 6
            case 28: keyIndex = 7
            default: keyIndex = 8
            }
            viewModel.copyAt(visibleIndex: keyIndex)
            return nil

        default:
            return event
        }
    }
}
