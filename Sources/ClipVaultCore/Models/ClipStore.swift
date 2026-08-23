import Foundation
import AppKit
import CryptoKit

/// Everything the store needs to persist one clipboard capture.
struct ClipCapture {
    var kind: ClipItem.Kind
    var text: String?
    /// Lossless PNG encoding of the captured image.
    var pngData: Data?
    /// Small thumbnail for fast list rendering.
    var thumbData: Data?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var filePaths: [String]?
    var htmlData: Data?
    var rtfData: Data?
    var sensitive: Bool
}

enum AddResult {
    case added(ClipItem)
    /// Content already existed; entry moved to top with refreshed timestamp.
    case moved(ClipItem)
    /// Identical to the current top item; nothing changed.
    case ignored
}

/// In-memory source of truth plus durable persistence for clipboard history.
///
/// Layout:
///   <dir>/manifest.json          – ordered metadata
///   <dir>/data/<uuid>.txt        – full text payload
///   <dir>/data/<uuid>.png        – full image payload
///   <dir>/data/<uuid>.thumb.png  – list thumbnail
///   <dir>/data/<uuid>.html/.rtf  – rich-text sidecars
///   <dir>/data/<uuid>.files      – JSON array of absolute paths
///
/// All mutating methods must be called on the main thread. Heavy disk work is
/// dispatched to a private serial queue; `flush()` blocks until persisted.
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    /// Monotonic change counter — lets consumers memoize derived state
    /// (e.g., the filtered visible list) without deep-comparing arrays.
    @Published private(set) var revision: Int = 0

    let directory: URL
    private let dataDirectory: URL
    private let configProvider: () -> HistoryConfig
    private let ioQueue = DispatchQueue(label: "app.clipvault.store.io", qos: .utility)
    private let saveLock = NSLock()
    private var debounceWork: DispatchWorkItem?

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipVault", isDirectory: true)
        return base
    }

    init(directory: URL = ClipStore.defaultDirectory(), configProvider: @escaping () -> HistoryConfig) {
        self.directory = directory
        self.dataDirectory = directory.appendingPathComponent("data", isDirectory: true)
        self.configProvider = configProvider
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    // MARK: - Queries

    func item(with id: UUID) -> ClipItem? {
        items.first { $0.id == id }
    }

    // MARK: - Mutation

    private func bumpRevision() {
        revision += 1
        objectWillChange.send()
    }

    @discardableResult
    func add(_ capture: ClipCapture, at date: Date = Date()) -> AddResult {
        let hash = Self.hash(for: capture)
        guard !hash.isEmpty else { return .ignored }

        // Identical to top → refresh timestamp only.
        if let first = items.first, first.contentHash == hash {
            items[0].createdAt = date
            resort()
            bumpRevision()
            scheduleSave()
            return .ignored
        }

        // Same content further down → move to top, merge sensitivity.
        if let idx = items.firstIndex(where: { $0.contentHash == hash }) {
            items[idx].createdAt = date
            if capture.sensitive { items[idx].sensitive = true }
            let moved = items.remove(at: idx)
            items.insert(moved, at: 0)
            resort()
            enforceLimit()
            bumpRevision()
            scheduleSave()
            return .moved(moved)
        }

        var preview: String?
        var charCount: Int?
        switch capture.kind {
        case .text:
            let raw = capture.text ?? ""
            charCount = raw.count
            preview = String(raw.prefix(400))
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            if preview?.isEmpty == true { preview = nil }
        default:
            break
        }

        let item = ClipItem(
            kind: capture.kind,
            createdAt: date,
            sensitive: capture.sensitive,
            contentHash: hash,
            textPreview: preview,
            characterCount: charCount,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight,
            byteSize: capture.kind == .text ? (capture.text?.utf8.count ?? 0) : (capture.pngData?.count ?? 0),
            filePaths: capture.filePaths,
            hasRichText: capture.htmlData != nil || capture.rtfData != nil
        )

        writePayloads(for: item, capture: capture)

        items.insert(item, at: 0)
        resort()
        enforceLimit()
        bumpRevision()
        scheduleSave()
        return .added(item)
    }

    func togglePin(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        items[idx].pinnedAt = items[idx].pinned ? Date() : nil
        resort()
        bumpRevision()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: idx)
        removePayloadFiles(for: removed)
        bumpRevision()
        scheduleSave()
    }

    /// Clears history. Pinned items survive unless `includingPinned` is true.
    func clearAll(includingPinned: Bool) {
        let doomed = items.filter { includingPinned || !$0.pinned }
        let doomedIDs = Set(doomed.map(\.id))
        items.removeAll { doomedIDs.contains($0.id) }
        doomed.forEach { removePayloadFiles(for: $0) }
        bumpRevision()
        scheduleSave()
    }

    /// Removes images older than the configured retention window. Returns count removed.
    @discardableResult
    func purgeExpiredImages(now: Date = Date(), retentionOverride: Int? = nil) -> Int {
        let days = retentionOverride ?? configProvider().imageRetentionDays
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let doomed = items.filter { $0.kind == .image && !$0.pinned && $0.createdAt < cutoff }
        guard !doomed.isEmpty else { return 0 }
        let doomedIDs = Set(doomed.map(\.id))
        items.removeAll { doomedIDs.contains($0.id) }
        doomed.forEach { removePayloadFiles(for: $0) }
        bumpRevision()
        scheduleSave()
        return doomed.count
    }

    // MARK: - Restore to pasteboard

    /// Blocks until all pending payload writes for the current history have hit
    /// disk. Called before any restore so a freshly captured item can never
    /// fail to copy-back due to an in-flight async write.
    func awaitPendingPayloadWrites() {
        ioQueue.sync { }
    }

    /// Writes the stored payload back to the given pasteboard. Returns false when
    /// the payload is missing (e.g., purged externally).
    @discardableResult
    func copyToPasteboard(_ id: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        awaitPendingPayloadWrites()
        guard let item = item(with: id) else { return false }
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            guard let text = readTextPayload(item) else { return false }
            guard pasteboard.setData(text.data(using: .utf8), forType: .string) else { return false }
            if let html = readSidecar(item, ext: "html") {
                pasteboard.setData(html, forType: .html)
            }
            if let rtf = readSidecar(item, ext: "rtf") {
                pasteboard.setData(rtf, forType: .rtf)
            }
            return true
        case .image:
            guard let png = readBinaryPayload(item, ext: "png") else { return false }
            guard pasteboard.setData(png, forType: .png) else { return false }
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return true
        case .files:
            // Legacy entries are migrated away on load; nothing to restore.
            return false
        }
    }

    // MARK: - Maintenance

    /// Applies capacity + retention rules immediately (e.g., right after the
    /// user changes them in Settings). Overrides are for tests/direct control;
    /// production callers rely on the config provider.
    func applyMaintenance(maxItems limitOverride: Int? = nil, imageRetentionDays retentionOverride: Int? = nil) {
        enforceLimit(maxItems: limitOverride)
        purgeExpiredImages(retentionOverride: retentionOverride)
    }

    // MARK: - Persistence

    /// Persists immediately. Runs *on* the IO queue so it can never race a
    /// debounced write that is already in flight (both would otherwise stage
    /// through the same temp file).
    func flush() {
        saveLock.lock()
        debounceWork?.cancel()
        debounceWork = nil
        saveLock.unlock()
        let snapshot = items
        ioQueue.sync { self.writeManifestSync(snapshot) }
    }

    private func scheduleSave() {
        saveLock.lock()
        debounceWork?.cancel()
        // Snapshot on the main thread: the encoder must never read `items`
        // concurrently with a main-thread mutation.
        let snapshot = items
        let work = DispatchWorkItem { [weak self] in self?.writeManifestSync(snapshot) }
        debounceWork = work
        saveLock.unlock()
        ioQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeManifestSync(_ snapshot: [ClipItem]) {
        let manifest = ClipItem.Manifest(items: snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        let tmp = directory.appendingPathComponent("manifest.\(UUID().uuidString).tmp")
        let dst = directory.appendingPathComponent("manifest.json")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            NSLog("ClipVault: manifest save failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() {
        let url = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { sweepOrphans(); return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            let data = try Data(contentsOf: url)
            let manifest = try decoder.decode(ClipItem.Manifest.self, from: data)
            // Drop entries whose payloads vanished externally, and migrate away
            // legacy file-reference entries (no longer supported by design).
            items = manifest.items.filter { $0.kind != .files && payloadExists($0) }
        } catch {
            NSLog("ClipVault: manifest load failed (%@); starting empty.", error.localizedDescription)
            items = []
        }
        resort()
        sweepOrphans()
    }

    /// Removes temp files and any payload no longer referenced by the manifest
    /// (e.g., leftovers from the removed files-kind). Runs synchronously at
    /// launch on the main thread — the one moment guaranteed race-free against
    /// future captures, and cheap (≤ a few hundred small files).
    private func sweepOrphans() {
        // Half-written manifests from a crash mid-save.
        if let strays = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) {
            for file in strays where file.lastPathComponent.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let referenced = Set(items.flatMap { payloadFileNames(for: $0) })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dataDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            if name.hasSuffix(".tmp") || !referenced.contains(name) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func payloadFileNames(for item: ClipItem) -> [String] {
        let id = item.id.uuidString
        switch item.kind {
        case .text:  return ["\(id).txt", "\(id).html", "\(id).rtf"]
        case .image: return ["\(id).png", "\(id).thumb.png"]
        case .files: return ["\(id).files"]
        }
    }

    // MARK: - Ordering / limits

    /// Invariant: pinned first (most recently pinned first), then unpinned newest-first.
    private func resort() {
        items.sort { a, b in
            switch (a.pinned, b.pinned) {
            case (true, false): return true
            case (false, true): return false
            case (true, true):  return (a.pinnedAt ?? .distantPast) > (b.pinnedAt ?? .distantPast)
            case (false, false): return a.createdAt > b.createdAt
            }
        }
    }

    private func enforceLimit(maxItems limitOverride: Int? = nil) {
        let maxItems = limitOverride ?? configProvider().maxItems
        var seenUnpinned = 0
        var doomed: [ClipItem] = []
        for item in items {
            if item.pinned { continue }
            seenUnpinned += 1
            if seenUnpinned > maxItems { doomed.append(item) }
        }
        guard !doomed.isEmpty else { return }
        let doomedIDs = Set(doomed.map(\.id))
        items.removeAll { doomedIDs.contains($0.id) }
        doomed.forEach { removePayloadFiles(for: $0) }
    }

    // MARK: - Payload storage

    private func writePayloads(for item: ClipItem, capture: ClipCapture) {
        let id = item.id
        ioQueue.async { [dataDirectory] in
            func write(_ data: Data?, _ name: String) {
                guard let data else { return }
                try? data.write(to: dataDirectory.appendingPathComponent(name), options: .atomic)
            }
            switch item.kind {
            case .text:
                write(capture.text?.data(using: .utf8), "\(id.uuidString).txt")
                write(capture.htmlData, "\(id.uuidString).html")
                write(capture.rtfData, "\(id.uuidString).rtf")
            case .image:
                write(capture.pngData, "\(id.uuidString).png")
                write(capture.thumbData, "\(id.uuidString).thumb.png")
            case .files:
                if let paths = capture.filePaths,
                   let data = try? JSONEncoder().encode(paths) {
                    write(data, "\(id.uuidString).files")
                }
            }
        }
    }

    private func removePayloadFiles(for item: ClipItem) {
        let id = item.id
        let exts = ["txt", "png", "thumb.png", "html", "rtf", "files"]
        ioQueue.async { [dataDirectory] in
            for ext in exts {
                try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("\(id.uuidString).\(ext)"))
            }
        }
    }

    private func payloadExists(_ item: ClipItem) -> Bool {
        switch item.kind {
        case .text:  return textURL(item).exists
        case .image: return pngURL(item).exists
        case .files: return false  // legacy kind — migrated away on load
        }
    }

    // MARK: - Payload reading

    func readTextPayload(_ item: ClipItem) -> String? {
        guard let data = try? Data(contentsOf: textURL(item)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func readImagePayload(_ item: ClipItem) -> Data? {
        try? Data(contentsOf: pngURL(item))
    }

    func readThumbnail(_ item: ClipItem) -> NSImage? {
        let url = dataDirectory.appendingPathComponent("\(item.id.uuidString).thumb.png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    private func readSidecar(_ item: ClipItem, ext: String) -> Data? {
        try? Data(contentsOf: dataDirectory.appendingPathComponent("\(item.id.uuidString).\(ext)"))
    }

    private func readBinaryPayload(_ item: ClipItem, ext: String) -> Data? {
        try? Data(contentsOf: dataDirectory.appendingPathComponent("\(item.id.uuidString).\(ext)"))
    }

    // MARK: - Paths

    private func textURL(_ item: ClipItem) -> URL { dataDirectory.appendingPathComponent("\(item.id.uuidString).txt") }
    private func pngURL(_ item: ClipItem) -> URL { dataDirectory.appendingPathComponent("\(item.id.uuidString).png") }

    // MARK: - Hashing

    static func hash(for capture: ClipCapture) -> String {
        let digest: SHA256Digest
        switch capture.kind {
        case .text:
            digest = SHA256.hash(data: Data((capture.text ?? "").utf8))
        case .image:
            digest = SHA256.hash(data: capture.pngData ?? Data())
        case .files:
            let joined = (capture.filePaths ?? []).joined(separator: "\u{1F}")
            digest = SHA256.hash(data: Data(joined.utf8))
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
