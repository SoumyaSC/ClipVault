import AppKit
import Foundation
@testable import ClipVaultCore

/// Classification decisions against real (scratch) pasteboards.
final class ClipboardClassifierTests: XCTestCase {

    private func scratchBoard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("cv-classifier-\(UUID().uuidString)"))
        return pb
    }

    private func policy(allowConcealed: Bool = false,
                        skipOTP: Bool = false,
                        source: String? = "com.test.source",
                        ignored: Set<String> = []) -> ClipboardClassifier.Policy {
        ClipboardClassifier.Policy(allowConcealed: allowConcealed,
                                   skipShortNumeric: skipOTP,
                                   sourceBundleID: source,
                                   ignoredBundleIDs: ignored)
    }

    // MARK: - Text

    func testPlainTextCaptured() {
        let pb = scratchBoard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("hello clipboard", forType: .string)

        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy()) else {
            return XCTFail("expected capture")
        }
        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.text, "hello clipboard")
        XCTAssertFalse(capture.sensitive)
    }

    func testMultipleStringsJoined() {
        let pb = scratchBoard()
        pb.clearContents()
        pb.writeObjects(["line one", "line two"] as [NSString])

        // readObjects returns both strings across pasteboard items.
        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy()) else {
            return XCTFail("expected capture")
        }
        XCTAssertEqual(capture.text, "line one\nline two")
    }

    func testWhitespaceOnlyStringSkipped() {
        let pb = scratchBoard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("   \n  ", forType: .string)

        if case .capture = ClipboardClassifier.classify(pb, policy: policy()) {
            XCTFail("whitespace-only must not be captured")
        }
    }

    func testRichTextSidecarsAttached() {
        let pb = scratchBoard()
        pb.declareTypes([.string, .html], owner: nil)
        pb.setString("styled", forType: .string)
        let html = Data("<i>styled</i>".utf8)
        pb.setData(html, forType: .html)

        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy()) else {
            return XCTFail("expected capture")
        }
        XCTAssertEqual(capture.htmlData, html)
        XCTAssertTrue(capture.rtfData == nil)
    }

    // MARK: - Concealed / transient

    private static let concealed = NSPasteboard.PasteboardType(ClipboardClassifier.concealedType)
    private static let transient = NSPasteboard.PasteboardType(ClipboardClassifier.transientType)

    func testConcealedSkippedByDefault() {
        let pb = scratchBoard()
        pb.declareTypes([.string, Self.concealed], owner: nil)
        pb.setString("hunter2", forType: .string)

        if case .capture = ClipboardClassifier.classify(pb, policy: policy(allowConcealed: false)) {
            XCTFail("concealed copies must be skipped by default")
        }
    }

    func testConcealedCapturedAsSensitiveWhenAllowed() {
        let pb = scratchBoard()
        pb.declareTypes([.string, Self.concealed], owner: nil)
        pb.setString("hunter2", forType: .string)

        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy(allowConcealed: true)) else {
            return XCTFail("expected capture")
        }
        XCTAssertTrue(capture.sensitive)
        XCTAssertEqual(capture.text, "hunter2")
    }

    func testTransientAlwaysSkipped() {
        let pb = scratchBoard()
        pb.declareTypes([.string, Self.transient], owner: nil)
        pb.setString("ephemeral", forType: .string)

        if case .capture = ClipboardClassifier.classify(pb, policy: policy(allowConcealed: true)) {
            XCTFail("transient copies must never be captured")
        }
    }

    // MARK: - Ignored apps

    func testIgnoredSourceAppSkipped() {
        let pb = scratchBoard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("from keychain", forType: .string)

        if case .capture = ClipboardClassifier.classify(
            pb,
            policy: policy(source: "com.1password.1password",
                           ignored: ["com.1password.1password"])
        ) {
            XCTFail("copies from ignored apps must be skipped")
        }
    }

    func testNonIgnoredSourceCaptured() {
        let pb = scratchBoard()
        pb.declareTypes([.string], owner: nil)
        pb.setString("normal copy", forType: .string)

        guard case .capture = ClipboardClassifier.classify(
            pb,
            policy: policy(source: "com.apple.Safari",
                           ignored: ["com.1password.1password"])
        ) else {
            return XCTFail("expected capture")
        }
    }

    // MARK: - OTP heuristic

    func testOTPSkipToggle() {
        func board(with number: String) -> NSPasteboard {
            let pb = scratchBoard()
            pb.declareTypes([.string], owner: nil)
            pb.setString(number, forType: .string)
            return pb
        }

        if case .capture = ClipboardClassifier.classify(board(with: "482913"), policy: policy(skipOTP: true)) {
            XCTFail("6-digit code should be skipped when OTP filter is on")
        }
        guard case .capture = ClipboardClassifier.classify(board(with: "482913"), policy: policy(skipOTP: false)) else {
            return XCTFail("same code should be captured when OTP filter is off")
        }
        // Longer numeric strings are legitimate content even with the filter on.
        guard case .capture = ClipboardClassifier.classify(board(with: "12345678901"), policy: policy(skipOTP: true)) else {
            return XCTFail("phone numbers must not be dropped")
        }
        // Non-numeric short strings pass.
        guard case .capture = ClipboardClassifier.classify(board(with: "a4b5c6"), policy: policy(skipOTP: true)) else {
            return XCTFail("alphanumeric codes must not be dropped")
        }
    }

    // MARK: - File copies (image files ingest as pixels; everything else skipped)

    private func makeTestPNG(width: Int = 9, height: Int = 7) throws -> (url: URL, cleanup: () -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cv-classifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("picture.png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        try rep.representation(using: .png, properties: [:])!.write(to: fileURL)
        return (fileURL, { try? FileManager.default.removeItem(at: dir) })
    }

    private func boardWithFile(_ url: URL) -> NSPasteboard {
        let pb = scratchBoard()
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        return pb
    }

    func testSingleImageFileIngestedAsPixels() throws {
        let png = try makeTestPNG()
        defer { png.cleanup() }

        guard case .capture(let capture) = ClipboardClassifier.classify(
            boardWithFile(png.url), policy: policy()) else {
            return XCTFail("expected image capture from image file")
        }
        XCTAssertEqual(capture.kind, .image)
        XCTAssertEqual(capture.pixelWidth, 9)
        XCTAssertEqual(capture.pixelHeight, 7)
        XCTAssertNotNil(capture.pngData)
        XCTAssertNotNil(capture.thumbData)
        XCTAssertNil(capture.filePaths, "must not carry file references")
    }

    /// Finder ships file-url + filename-as-string together; the image must
    /// still win over its own name.
    func testFinderStyleImageFileWithFilenameStringIngested() throws {
        let png = try makeTestPNG(width: 11, height: 5)
        defer { png.cleanup() }

        let pb = scratchBoard()
        pb.clearContents()
        pb.writeObjects([png.url as NSURL])
        pb.addTypes([.string], owner: nil)
        pb.setString(png.url.lastPathComponent, forType: .string)

        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy()) else {
            return XCTFail("expected image capture despite accompanying filename string")
        }
        XCTAssertEqual(capture.kind, .image)
        XCTAssertNotEqual(capture.text, png.url.lastPathComponent, "must not store the filename as text")
    }

    /// A real text payload next to a file reference stays a text capture.
    func testFileReferenceWithRealTextKeepsText() throws {
        let png = try makeTestPNG()
        defer { png.cleanup() }

        let pb = scratchBoard()
        pb.clearContents()
        pb.writeObjects([png.url as NSURL])
        pb.addTypes([.string], owner: nil)
        pb.setString("actual caption text", forType: .string)

        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy()) else {
            return XCTFail("expected text capture")
        }
        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.text, "actual caption text")
    }

    func testNonImageFileSkipped() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cv-classifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("doc.pdf")
        try Data("pdf-bytes".utf8).write(to: pdf)

        if case .capture(let capture) = ClipboardClassifier.classify(boardWithFile(pdf), policy: policy()) {
            XCTFail("non-image files must never be stored; got \(capture.kind)")
        }
    }

    func testMultipleFileCopiesSkipped() throws {
        let png = try makeTestPNG()
        defer { png.cleanup() }
        let second = png.url.deletingLastPathComponent().appendingPathComponent("other.png")
        try Data().write(to: second)

        let pb = scratchBoard()
        pb.clearContents()
        pb.writeObjects([png.url as NSURL, second as NSURL])

        if case .capture = ClipboardClassifier.classify(pb, policy: policy()) {
            XCTFail("multi-file copies must not be stored")
        }
    }

    func testCorruptImageFileSkipped() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cv-classifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fake.png")
        try Data("not-an-image".utf8).write(to: fake)

        if case .capture = ClipboardClassifier.classify(boardWithFile(fake), policy: policy()) {
            XCTFail("corrupt image files must be skipped")
        }
    }

    // MARK: - Images

    func testImageCapturedWithDimensionsAndThumbnail() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 7, pixelsHigh: 5,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 28, bitsPerPixel: 32
        )!
        let tiff = rep.tiffRepresentation!

        let pb = scratchBoard()
        pb.declareTypes([.tiff], owner: nil)
        pb.setData(tiff, forType: .tiff)

        guard case .capture(let capture) = ClipboardClassifier.classify(pb, policy: policy()) else {
            return XCTFail("expected capture")
        }
        XCTAssertEqual(capture.kind, .image)
        XCTAssertEqual(capture.pixelWidth, 7)
        XCTAssertEqual(capture.pixelHeight, 5)
        XCTAssertNotNil(capture.pngData)
        XCTAssertNotNil(capture.thumbData)
        XCTAssertLessThanOrEqual(capture.thumbData!.count, capture.pngData!.count)
    }

    func testOversizedImageRefused() {
        // A 1×1 PNG is tiny; force refusal via an absurdly small cap instead of
        // synthesising hundreds of megabytes.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 8, bitsPerPixel: 32
        )!
        let tiff = rep.tiffRepresentation!

        let pb = scratchBoard()
        pb.declareTypes([.tiff], owner: nil)
        pb.setData(tiff, forType: .tiff)

        if ClipboardClassifier.imagePayload(from: pb, maxBytes: 10) != nil {
            XCTFail("oversized payload must be refused")
        }
    }

    // MARK: - Hashing

    func testHashDistinguishesContent() {
        let a = ClipCapture(kind: .text, text: "alpha", pngData: nil, thumbData: nil,
                            pixelWidth: nil, pixelHeight: nil, filePaths: nil,
                            htmlData: nil, rtfData: nil, sensitive: false)
        let b = ClipCapture(kind: .text, text: "beta", pngData: nil, thumbData: nil,
                            pixelWidth: nil, pixelHeight: nil, filePaths: nil,
                            htmlData: nil, rtfData: nil, sensitive: false)
        let a2 = ClipCapture(kind: .text, text: "alpha", pngData: nil, thumbData: nil,
                             pixelWidth: nil, pixelHeight: nil, filePaths: nil,
                             htmlData: nil, rtfData: nil, sensitive: false)
        XCTAssertNotEqual(ClipStore.hash(for: a), ClipStore.hash(for: b))
        XCTAssertEqual(ClipStore.hash(for: a), ClipStore.hash(for: a2))
    }

    // MARK: - Sensitivity of image captures

    func testConcealedImageIsCapturedAsSensitive() throws {
        let png = try makeTestPNG()
        defer { png.cleanup() }
        let raw = try Data(contentsOf: png.url)

        let pb = scratchBoard()
        pb.declareTypes([.png, Self.concealed], owner: nil)
        pb.setData(raw, forType: .png)

        guard case .capture(let capture) = ClipboardClassifier.classify(
            pb, policy: policy(allowConcealed: true)) else {
            return XCTFail("expected image capture")
        }
        XCTAssertEqual(capture.kind, .image)
        XCTAssertTrue(capture.sensitive, "a concealed image must stay maskable in the list")
    }

    func testConcealedImageFileIsCapturedAsSensitive() throws {
        let png = try makeTestPNG()
        defer { png.cleanup() }

        let pb = scratchBoard()
        pb.clearContents()
        pb.writeObjects([png.url as NSURL])
        pb.setData(Data(), forType: Self.concealed)

        guard case .capture(let capture) = ClipboardClassifier.classify(
            pb, policy: policy(allowConcealed: true)) else {
            return XCTFail("expected image capture from concealed image file")
        }
        XCTAssertEqual(capture.kind, .image)
        XCTAssertTrue(capture.sensitive)
    }

    // MARK: - Settings persistence

    @MainActor
    func testRetentionNeverSurvivesRelaunch() {
        let suite = MemoryDefaults()
        let first = SettingsStore(defaults: suite)
        first.imageRetentionDays = 0          // "Never expire automatically"

        let reloaded = SettingsStore(defaults: suite)
        XCTAssertEqual(reloaded.imageRetentionDays, 0, "Never must survive a relaunch")
    }

    @MainActor
    func testOutOfRangePersistedSettingsAreRepaired() {
        let suite = MemoryDefaults()
        suite.set(9_999, forKey: "cv.maxItems")
        suite.set(13, forKey: "cv.imageRetentionDays")   // not an offered choice

        let settings = SettingsStore(defaults: suite)
        XCTAssertEqual(settings.maxItems, 1000)
        XCTAssertEqual(settings.imageRetentionDays, 30)
    }

    @MainActor
    func testEveryRetentionChoiceRoundTrips() {
        for choice in SettingsStore.retentionChoices {
            let suite = MemoryDefaults()
            let store = SettingsStore(defaults: suite)
            store.imageRetentionDays = choice
            XCTAssertEqual(SettingsStore(defaults: suite).imageRetentionDays, choice,
                           "retention choice \(choice) must persist")
        }
    }

    @MainActor
    func testSettingsDefaultsMatchProductDecisions() {
        let settings = SettingsStore(defaults: MemoryDefaults())

        XCTAssertEqual(settings.maxItems, 200)
        XCTAssertEqual(settings.imageRetentionDays, 30)
        XCTAssertTrue(settings.skipConcealed, "password-manager skip must default ON")
        XCTAssertTrue(settings.maskSensitive)
        XCTAssertFalse(settings.skipShortNumeric, "OTP heuristic defaults OFF to avoid data loss")
        XCTAssertTrue(settings.hotKeyEnabled)
        XCTAssertFalse(settings.dockIconEnabled, "Dock icon off by default")
        XCTAssertTrue(settings.ignoredBundleIDs.contains("com.1password.1password"))
    }
}
