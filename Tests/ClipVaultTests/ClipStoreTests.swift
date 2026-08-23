import Foundation
import AppKit
@testable import ClipVaultCore

/// Exercises the persistence layer end-to-end against a temporary directory.
final class ClipStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipvault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func makeStore(maxItems: Int = 200, imageRetentionDays: Int = 30) -> ClipStore {
        ClipStore(directory: root) { HistoryConfig(maxItems: maxItems, imageRetentionDays: imageRetentionDays) }
    }

    private func textCapture(_ text: String, sensitive: Bool = false) -> ClipCapture {
        // sensitive flag flows straight into the capture
        ClipCapture(kind: .text, text: text,
                    pngData: nil, thumbData: nil,
                    pixelWidth: nil, pixelHeight: nil, filePaths: nil,
                    htmlData: nil, rtfData: nil, sensitive: sensitive)
    }

    /// Lets background payload writes land.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: - Capture & ordering

    func testAddTextInsertsAtTopAndPersistsPayload() throws {
        let store = makeStore()
        _ = store.add(textCapture("hello world"))

        XCTAssertEqual(store.items.first?.textPreview, "hello world")
        XCTAssertEqual(store.items.first?.characterCount, 11)

        store.flush()
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: self.root.appendingPathComponent("data").appendingPathComponent("\(store.items[0].id.uuidString).txt").path)
        })
        let payload = try String(contentsOf: root.appendingPathComponent("data").appendingPathComponent("\(store.items[0].id.uuidString).txt"), encoding: .utf8)
        XCTAssertEqual(payload, "hello world")
    }

    func testReCopyOfOlderItemMovesItToTop() {
        let store = makeStore()
        _ = store.add(textCapture("alpha"))
        _ = store.add(textCapture("beta"))
        XCTAssertEqual(store.items.map(\.textPreview), ["beta", "alpha"])

        // Wait so timestamps differ deterministically.
        Thread.sleep(forTimeInterval: 0.01)
        let result = store.add(textCapture("alpha"))

        guard case .moved(let moved) = result else {
            return XCTFail("expected .moved, got \(result)")
        }
        XCTAssertEqual(moved.textPreview, "alpha")
        XCTAssertEqual(store.items.map(\.textPreview), ["alpha", "beta"])
        XCTAssertEqual(store.items.count, 2, "must not duplicate")
    }

    func testIdenticalTopCopyIsIgnored() {
        let store = makeStore()
        _ = store.add(textCapture("same"))
        let result = store.add(textCapture("same"))
        guard case .ignored = result else {
            return XCTFail("expected .ignored, got \(result)")
        }
        XCTAssertEqual(store.items.count, 1)
    }

    func testSensitivityEscalatesOnMove() {
        let store = makeStore()
        _ = store.add(textCapture("secret-ish"))
        _ = store.add(textCapture("other"))
        _ = store.add(textCapture("secret-ish", sensitive: true))
        XCTAssertTrue(store.items[0].sensitive, "later concealed capture must escalate flag")
    }
    func testSensitivityStaysWhenRecapturedPlain() {
        let store = makeStore()
        _ = store.add(textCapture("secret-ish", sensitive: true))
        _ = store.add(textCapture("other"))
        Thread.sleep(forTimeInterval: 0.01)
        _ = store.add(textCapture("secret-ish"))
        XCTAssertTrue(store.items[0].sensitive, "flag must never downgrade on recapture")
    }

    // MARK: - Limits & pins

    func testLimitEvictsOldestUnpinnedOnly() {
        let store = makeStore(maxItems: 3)
        _ = store.add(textCapture("one"))
        _ = store.add(textCapture("two"))
        _ = store.add(textCapture("three"))
        store.togglePin(store.items[0].id)      // pin newest ("three")
        Thread.sleep(forTimeInterval: 0.01)
        _ = store.add(textCapture("four"))
        Thread.sleep(forTimeInterval: 0.01)
        _ = store.add(textCapture("five"))      // pushes unpinned count over limit

        let previews = store.items.map { $0.textPreview ?? "" }
        XCTAssertTrue(previews.contains("three"), "pinned item must survive eviction")
        XCTAssertFalse(previews.contains("one"), "oldest unpinned should be evicted")
        XCTAssertLessThanOrEqual(store.items.filter { !$0.pinned }.count, 3)
    }

    func testPinnedSortsAboveChronological() {
        let store = makeStore()
        _ = store.add(textCapture("a"))
        _ = store.add(textCapture("b"))
        store.togglePin(store.items[1].id)  // pin "a" (older)

        XCTAssertEqual(store.items.map(\.textPreview), ["a", "b"])

        store.togglePin(store.items[0].id)  // unpin again
        XCTAssertEqual(store.items.map(\.textPreview), ["b", "a"])
    }

    // MARK: - Persistence

    func testRoundTripAcrossInstances() throws {
        let first = makeStore()
        _ = first.add(textCapture("persist me"))
        first.flush()

        let second = makeStore()
        XCTAssertEqual(second.items.map(\.textPreview), ["persist me"])
    }

    func testMissingPayloadDropsEntryOnLoad() throws {
        let first = makeStore()
        _ = first.add(textCapture("will vanish"))
        _ = first.add(textCapture("survives"))
        first.flush()
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: self.root.appendingPathComponent("data").appendingPathComponent("\(first.items[0].id.uuidString).txt").path)
                && FileManager.default.fileExists(atPath: self.root.appendingPathComponent("data").appendingPathComponent("\(first.items[1].id.uuidString).txt").path)
        })

        // Simulate external corruption: delete the payload of "will vanish"
        // (items[1]); items[0] is the newer "survives".
        let doomedID = first.items[1].id
        XCTAssertEqual(first.items[1].textPreview, "will vanish")
        try FileManager.default.removeItem(at: root.appendingPathComponent("data").appendingPathComponent("\(doomedID.uuidString).txt"))

        let second = makeStore()
        XCTAssertEqual(second.items.map(\.textPreview), ["survives"])
    }

    // MARK: - Deletion & clearing

    func testDeleteRemovesPayloadFile() throws {
        let store = makeStore()
        _ = store.add(textCapture("doomed"))
        let id = store.items[0].id
        store.delete(id)
        store.flush()

        let url = root.appendingPathComponent("data").appendingPathComponent("\(id.uuidString).txt")
        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: url.path) })
        XCTAssertTrue(store.items.isEmpty)
    }

    func testClearAllKeepsPinnedUnlessForced() {
        let store = makeStore()
        _ = store.add(textCapture("pinned"))
        _ = store.add(textCapture("plain"))
        store.togglePin(store.items[1].id)      // older entry carries the pin

        store.clearAll(includingPinned: false)
        XCTAssertEqual(store.items.map(\.textPreview), ["pinned"])

        store.clearAll(includingPinned: true)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Image retention

    private func imageCapture(width: Int = 2) -> ClipCapture {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        let png = rep.representation(using: .png, properties: [:])!
        let thumb = ClipboardClassifier.thumbnailData(from: png)
        return ClipCapture(kind: .image, text: nil,
                           pngData: png, thumbData: thumb,
                           pixelWidth: width, pixelHeight: 2, filePaths: nil,
                           htmlData: nil, rtfData: nil, sensitive: false)
    }

    func testImagePurgeRespectsRetentionAndPins() {
        let store = makeStore(imageRetentionDays: 7)
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        _ = store.add(imageCapture(width: 2), at: oldDate)          // expired
        _ = store.add(textCapture("old text"), at: oldDate)             // text never expires
        _ = store.add(imageCapture(width: 3), at: oldDate)
        store.togglePin(store.items[0].id)                              // pin newest image

        let removed = store.purgeExpiredImages(now: Date(), retentionOverride: 7)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.items.count, 2, "pinned image and old text survive")
        XCTAssertTrue(store.items.contains { $0.pinned }, "pinned image must remain")
        XCTAssertTrue(store.items.contains { $0.kind == .text }, "text must never age out")
    }

    func testZeroRetentionDisablesPurge() {
        let store = makeStore(imageRetentionDays: 0)
        let oldDate = Date().addingTimeInterval(-400 * 86_400)
        _ = store.add(imageCapture(), at: oldDate)
        XCTAssertEqual(store.purgeExpiredImages(retentionOverride: 0), 0)
        XCTAssertEqual(store.items.count, 1)
    }

    // MARK: - Restore

    func testCopyRestoresTextAndRichSidecars() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("cv-test-copy-\(UUID().uuidString)"))

        let store = makeStore()
        let html = "<b>bold</b>".data(using: .utf8)!
        _ = store.add(ClipCapture(kind: .text, text: "plain body",
                                  pngData: nil, thumbData: nil,
                                  pixelWidth: nil, pixelHeight: nil, filePaths: nil,
                                  htmlData: html, rtfData: nil, sensitive: false))
        store.flush()
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: self.root.appendingPathComponent("data").appendingPathComponent("\(store.items[0].id.uuidString).html").path)
        })

        XCTAssertTrue(store.copyToPasteboard(store.items[0].id, pasteboard: pb))
        XCTAssertEqual(pb.string(forType: .string), "plain body")
        XCTAssertEqual(pb.data(forType: .html), html)
    }

    func testCopyFailsGracefullyWhenPayloadMissing() throws {
        let store = makeStore()
        _ = store.add(textCapture("gone soon"))
        store.flush()
        let id = store.items[0].id
        XCTAssertTrue(waitUntil {
            FileManager.default.fileExists(atPath: self.root.appendingPathComponent("data").appendingPathComponent("\(id.uuidString).txt").path)
        })
        try FileManager.default.removeItem(at: root.appendingPathComponent("data").appendingPathComponent("\(id.uuidString).txt"))

        let pb = NSPasteboard(name: NSPasteboard.Name("cv-test-missing-\(UUID().uuidString)"))
        XCTAssertFalse(store.copyToPasteboard(id, pasteboard: pb))
    }

    // MARK: - Copy-back determinism (toast bug regression)

    func testImmediateCopyBackAfterCaptureSucceeds() throws {
        let store = makeStore()
        _ = store.add(textCapture("instant restore"))

        // No sleeps, no polling — the store must resolve pending payload
        // writes before restoring, or the UI shows a false failure.
        let pb = NSPasteboard(name: NSPasteboard.Name("cv-test-instant-\(UUID().uuidString)"))
        XCTAssertTrue(store.copyToPasteboard(store.items[0].id, pasteboard: pb))
        XCTAssertEqual(pb.string(forType: .string), "instant restore")
    }

    // MARK: - Legacy files-kind migration

    func testLegacyFilesEntriesAreMigratedAway() throws {
        let legacyID = UUID()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let legacy = ClipItem(kind: .files,
                              createdAt: Date(),
                              contentHash: String(repeating: "a", count: 64),
                              filePaths: ["/tmp/nope.txt"])
        let keeper = ClipItem(kind: .text,
                              createdAt: Date(),
                              contentHash: String(repeating: "b", count: 64))
        let manifest = ClipItem.Manifest(items: [legacy, keeper])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try "kept".write(to: dataDir.appendingPathComponent("\(keeper.id.uuidString).txt"), atomically: true, encoding: .utf8)
        try "[\"/tmp/nope.txt\"]".write(to: dataDir.appendingPathComponent("\(legacyID.uuidString).files"), atomically: true, encoding: .utf8)
        try Data().write(to: dataDir.appendingPathComponent("\(legacy.id.uuidString).files"))
        try Data().write(to: dataDir.appendingPathComponent("stray-orphan.bin"))

        let store = makeStore()

        XCTAssertEqual(store.items.map(\.id), [keeper.id], "legacy files entry must be dropped")
        store.flush()
        XCTAssertTrue(waitUntil {
            !FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("\(legacy.id.uuidString).files").path)
                && !FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("stray-orphan.bin").path)
                && FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("\(keeper.id.uuidString).txt").path)
        }, "orphan payloads must be swept, live payloads kept")
    }

    // MARK: - Maintenance

    func testApplyMaintenanceTrimsAndPurgesImmediately() {
        let store = makeStore(maxItems: 10, imageRetentionDays: 0)
        for i in 0..<15 {
            _ = store.add(textCapture("item \(i)"))
            Thread.sleep(forTimeInterval: 0.004)
        }
        XCTAssertEqual(store.items.count, 10, "configured cap applies at capture time")

        // Simulate the user lowering the cap in Settings, then applying it.
        store.applyMaintenance(maxItems: 5, imageRetentionDays: 0)
        XCTAssertEqual(store.items.count, 5)
        XCTAssertEqual(store.items.first?.textPreview, "item 14", "newest survives")
        XCTAssertEqual(store.items.last?.textPreview, "item 10", "oldest evicted")
    }
}
