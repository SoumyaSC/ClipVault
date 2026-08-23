import Foundation
import SwiftUI
import Combine

@MainActor
final class HistoryViewModel: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case text = "Text"
        case images = "Images"
        case pinned = "Pinned"

        var id: String { rawValue }
    }

    @Published var query = ""
    @Published var filter: Filter = .all
    @Published var selectionIndex = 0
    @Published var focusSearchToken = 0
    /// Row currently showing the copied/error flash.
    @Published var flashID: UUID?
    /// True while the current flash signals a copy *failure*.
    @Published var flashIsError = false

    let context = AppContext.shared
    var settings: SettingsStore { context.settings }

    private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>()
        c.countLimit = 400
        return c
    }()
    private var cancellables = Set<AnyCancellable>()
    private var flashWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    // Visible-list memoization: recomputed only when the store changes,
    // or the query/filter changes.
    private var visibleCacheKey: (Int, String, Filter)?
    private var visibleCacheValue: [ClipItem] = []

    init() {
        context.store.objectWillChange
            .sink { [weak self] _ in self?.invalidateVisible() }
            .store(in: &cancellables)
    }

    func invalidateVisible() {
        visibleCacheKey = nil
        objectWillChange.send()
    }

    /// Called every time the panel opens.
    func beginSession() {
        selectionIndex = 0
        query = ""
        filter = .all
        needsScroll = false
    }

    // MARK: - Derived data

    var visibleItems: [ClipItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = (context.store.revision, normalizedQuery, filter)
        if let cachedKey = visibleCacheKey, cachedKey == key {
            return visibleCacheValue
        }
        let result = computeVisible(queryKey: normalizedQuery)
        visibleCacheKey = key
        visibleCacheValue = result
        return result
    }

    private func computeVisible(queryKey: String) -> [ClipItem] {
        context.store.items.filter { item in
            switch filter {
            case .all: break
            case .text where item.kind == .text: break
            case .images where item.kind == .image: break
            case .pinned where item.pinned: break
            default: return false
            }
            guard !queryKey.isEmpty else { return true }
            if let preview = item.textPreview, preview.lowercased().contains(queryKey) {
                return true
            }
            return false
        }
    }

    var selectedItem: ClipItem? {
        let visible = visibleItems
        guard !visible.isEmpty else { return nil }
        return visible[min(selectionIndex, visible.count - 1)]
    }

    func moveSelection(_ delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selectionIndex = max(0, min(count - 1, selectionIndex + delta))
        needsScroll = true
    }

    /// Keyboard navigation requests a scroll; click-selection must not (it
    /// would animate the list mid-flash and can disrupt the toast).
    @Published var needsScroll = false

    /// Click-selection without scrolling.
    func select(itemID: UUID) {
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            selectionIndex = idx
        }
    }

    // MARK: - Actions

    func copy(_ item: ClipItem) {
        guard context.performCopy(item) else {
            // Never fail silently — surface a readable error state on the row.
            showFlash(id: item.id, isError: true)
            return
        }
        showFlash(id: item.id, isError: false)
        if settings.autoCloseOnCopy {
            scheduleClose()
        }
    }

    func quickPaste(_ item: ClipItem) {
        context.performQuickPaste(item)
    }

    func copySelected() {
        if let item = selectedItem { copy(item) }
    }

    func quickPasteSelected() {
        if let item = selectedItem { quickPaste(item) }
    }

    func deleteSelected() {
        if let item = selectedItem {
            delete(item)
        }
    }

    func copyAt(visibleIndex: Int) {
        let visible = visibleItems
        guard visibleIndex < visible.count else { return }
        copy(visible[visibleIndex])
    }

    func togglePin(_ item: ClipItem) {
        context.store.togglePin(item.id)
    }

    func delete(_ item: ClipItem) {
        if flashID == item.id { flashID = nil }
        context.store.delete(item.id)
        clampSelection()
    }

    func clearAll(includingPinned: Bool) {
        context.store.clearAll(includingPinned: includingPinned)
        clampSelection()
    }

    func dismissWelcome() {
        settings.welcomeShown = true
    }

    var showWelcome: Bool { !settings.welcomeShown }

    func openSettings() {
        NotificationCenter.default.post(name: .cvOpenSettings, object: nil)
    }

    // MARK: - Helpers

    /// Shows the row-level confirmation badge. Success flashes long enough to
    /// be perceived (1.0s); the panel auto-close is scheduled AFTER it, so a
    /// toast can never be cut short.
    private func showFlash(id: UUID, isError: Bool) {
        flashWork?.cancel()
        flashID = id
        flashIsError = isError
        let duration: TimeInterval = isError ? 1.8 : 1.0
        let work = DispatchWorkItem { [weak self] in self?.flashID = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: item.id as NSUUID) {
            return cached
        }
        guard let image = context.store.readThumbnail(item) else { return nil }
        thumbnailCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .cvClosePopover, object: nil)
        }
        closeWork = work
        // Wait out the full success flash before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: work)
    }

    private func clampSelection() {
        let count = visibleItems.count
        if count == 0 {
            selectionIndex = 0
        } else if selectionIndex >= count {
            selectionIndex = count - 1
        }
    }
}
