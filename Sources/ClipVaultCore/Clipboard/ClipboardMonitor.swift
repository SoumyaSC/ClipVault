import Foundation
import AppKit
import ImageIO

/// Pure decision layer over a pasteboard snapshot. Isolated from timers so it can
/// be exercised directly in unit tests with scratch pasteboards.
enum ClipboardClassifier {

    enum Decision {
        case capture(ClipCapture)
        case skip(String)
    }

    struct Policy {
        var allowConcealed: Bool
        var skipShortNumeric: Bool
        var sourceBundleID: String?
        var ignoredBundleIDs: Set<String>
        /// Payloads larger than this are refused (bytes).
        var maxImageBytes: Int = 30 * 1_000_000

        @MainActor
        static func live(from settings: SettingsStore, bundleID: String?) -> Policy {
            Policy(allowConcealed: !settings.skipConcealed,
                   skipShortNumeric: settings.skipShortNumeric,
                   sourceBundleID: bundleID,
                   ignoredBundleIDs: Set(settings.ignoredBundleIDs))
        }
    }

    // nspasteboard.org conventions honoured by 1Password, Bitwarden, KeePassXC…
    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"

    /// Cheap routing result: images come back UNENCODED so the caller can
    /// finish them on a background queue.
    enum QuickDecision {
        case capture(ClipCapture)
        case pendingImage(data: Data, isDirectPNG: Bool, sensitive: Bool)
        case pendingImageFile(URL, sensitive: Bool)
        case skip(String)
    }

    /// Guard checks + text/files/image routing with zero heavy work.
    static func quickRoute(_ pasteboard: NSPasteboard, policy: Policy) -> QuickDecision {
        let types = (pasteboard.types ?? []).map(\.rawValue)

        if types.contains(transientType) || types.contains(where: { $0.lowercased().contains("transient") }) {
            return .skip("transient")
        }

        let concealed = types.contains(concealedType)
        if concealed && !policy.allowConcealed {
            return .skip("concealed")
        }

        if let src = policy.sourceBundleID, policy.ignoredBundleIDs.contains(src) {
            return .skip("ignored-app")
        }

        let strings = (pasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let joined = strings.joined(separator: "\n")

        // File copies take precedence when the string is merely the filename
        // or path (Finder ships both together) — a single *image* file is then
        // ingested as pixels. Any other accompanying text is real content and
        // wins as a text capture.
        let hasFileFlavor = types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
        if hasFileFlavor {
            let filePaths = extractFileURLs(pasteboard)
            if filePaths.count == 1 {
                let url = filePaths[0]
                let stringIsJustFilename = joined.isEmpty
                    || joined == url.lastPathComponent
                    || joined == url.path
                if stringIsJustFilename {
                    return .pendingImageFile(url, sensitive: concealed)
                }
                return .capture(ClipCapture(kind: .text,
                                            text: joined,
                                            pngData: nil, thumbData: nil,
                                            pixelWidth: nil, pixelHeight: nil,
                                            filePaths: nil,
                                            htmlData: pasteboard.data(forType: .html),
                                            rtfData: pasteboard.data(forType: .rtf),
                                            sensitive: concealed))
            }
            return .skip(filePaths.isEmpty ? "file-unreadable" : "file-not-image")
        }

        if !joined.isEmpty {
            if policy.skipShortNumeric,
               joined.count <= 8,
               joined.allSatisfy({ $0.isNumber }) {
                return .skip("likely-otp")
            }
            return .capture(ClipCapture(kind: .text,
                                        text: joined,
                                        pngData: nil, thumbData: nil,
                                        pixelWidth: nil, pixelHeight: nil,
                                        filePaths: nil,
                                        htmlData: pasteboard.data(forType: .html),
                                        rtfData: pasteboard.data(forType: .rtf),
                                        sensitive: concealed))
        }

        if let raw = rawImagePayload(from: pasteboard, maxBytes: policy.maxImageBytes) {
            return .pendingImage(data: raw.data, isDirectPNG: raw.isDirectPNG, sensitive: concealed)
        }

        return .skip("unhandled")
    }

    /// Fully synchronous classification (used by tests and any caller that
    /// wants finished captures immediately).
    static func classify(_ pasteboard: NSPasteboard, policy: Policy) -> Decision {
        switch quickRoute(pasteboard, policy: policy) {
        case .capture(let capture):
            return .capture(capture)
        case .pendingImage(let data, let isDirectPNG, let sensitive):
            if let capture = finalizeImageCapture(data, isDirectPNG: isDirectPNG,
                                                  maxBytes: policy.maxImageBytes, sensitive: sensitive) {
                return .capture(capture)
            }
            return .skip("image-encode-failed")
        case .pendingImageFile(let url, let sensitive):
            if let capture = imageFromFile(at: url, maxBytes: policy.maxImageBytes, sensitive: sensitive) {
                return .capture(capture)
            }
            return .skip("file-not-image")
        case .skip(let reason):
            return .skip(reason)
        }
    }

    /// Resolves file URLs robustly across pasteboard writers — `readObjects`
    /// first, then per-item raw data (some apps only declare the flavor).
    static func extractFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = objects.filter(\.isFileURL)
            if !files.isEmpty {
                return files
            }
        }
        var result: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: .fileURL),
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string),
                  url.isFileURL else { continue }
            result.append(url)
        }
        return result
    }

    // MARK: - Image plumbing

    /// Loads an image file from disk and re-encodes it as a PNG capture.
    static func imageFromFile(at url: URL, maxBytes: Int, sensitive: Bool = false) -> ClipCapture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let pngData = rep.representation(using: .png, properties: [:]),
              pngData.count <= maxBytes else { return nil }

        return ClipCapture(kind: .image,
                           text: nil,
                           pngData: pngData,
                           thumbData: thumbnailData(from: pngData),
                           pixelWidth: rep.pixelsWide,
                           pixelHeight: rep.pixelsHigh,
                           filePaths: nil,
                           htmlData: nil, rtfData: nil,
                           sensitive: sensitive)
    }

    /// Raw image bytes straight from the pasteboard — no encoding yet, safe
    /// to read on the main thread even for large screenshots.
    static func rawImagePayload(from pasteboard: NSPasteboard, maxBytes: Int) -> (data: Data, isDirectPNG: Bool)? {
        if let direct = pasteboard.data(forType: .png), direct.count <= maxBytes {
            return (direct, true)
        }
        if let tiff = pasteboard.data(forType: .tiff), tiff.count <= maxBytes {
            return (tiff, false)
        }
        return nil
    }

    /// Single source of truth for turning raw image bytes into a finished
    /// capture (PNG normalisation + thumbnail + dimensions). Heavy — run off-main.
    static func finalizeImageCapture(_ rawData: Data, isDirectPNG: Bool, maxBytes: Int, sensitive: Bool = false) -> ClipCapture? {
        var pngData: Data?
        if isDirectPNG {
            pngData = rawData
        } else if let rep = NSBitmapImageRep(data: rawData) {
            pngData = rep.representation(using: .png, properties: [:])
        }
        guard let pngData,
              pngData.count <= maxBytes,
              let rep = NSBitmapImageRep(data: pngData),
              rep.pixelsWide > 0 else { return nil }

        return ClipCapture(kind: .image,
                           text: nil,
                           pngData: pngData,
                           thumbData: thumbnailData(from: pngData),
                           pixelWidth: rep.pixelsWide,
                           pixelHeight: rep.pixelsHigh,
                           filePaths: nil,
                           htmlData: nil, rtfData: nil,
                           sensitive: sensitive)
    }

    /// Synchronous convenience wrapper.
    static func imagePayload(from pasteboard: NSPasteboard, maxBytes: Int, sensitive: Bool = false) -> ClipCapture? {
        guard let raw = rawImagePayload(from: pasteboard, maxBytes: maxBytes) else { return nil }
        return finalizeImageCapture(raw.data, isDirectPNG: raw.isDirectPNG, maxBytes: maxBytes, sensitive: sensitive)
    }

    static func thumbnailData(from png: Data, maxPixel: CGFloat = 192) -> Data? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Polls the system pasteboard and forwards fresh captures to the store.
/// Confined to the main actor: the run-loop timer fires there and every
/// consumer (store, workspace queries) is main-thread bound anyway.
@MainActor
final class ClipboardMonitor {

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastHandledChange: Int = 0
    private let onCapture: (ClipCapture) -> Void

    init(onCapture: @escaping (ClipCapture) -> Void) {
        self.onCapture = onCapture
    }

    /// Call after programmatically writing the pasteboard so our own change is
    /// not re-captured.
    func suppressCurrentChange() {
        lastHandledChange = pasteboard.changeCount
    }

    func start(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        lastHandledChange = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let countAtStart = pasteboard.changeCount
        guard countAtStart != lastHandledChange else { return }

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Resolved once, here on the main actor: the background finaliser below
        // must never read main-actor settings from its own queue.
        let policy = ClipboardClassifier.Policy.live(from: SettingsStore.shared, bundleID: frontBundle)
        let maxImageBytes = policy.maxImageBytes

        // Cheap routing only — no PNG encoding on the main thread, ever.
        let decision = ClipboardClassifier.quickRoute(pasteboard, policy: policy)

        // Writer changed mid-read; retry on the next tick with the newer content.
        guard pasteboard.changeCount == countAtStart else {
            lastHandledChange = pasteboard.changeCount
            return
        }
        lastHandledChange = countAtStart

        switch decision {
        case .capture(let capture):
            onCapture(capture)

        case .pendingImage(let data, let isDirectPNG, let sensitive):
            finishOnBackground(changeAtStart: countAtStart) {
                ClipboardClassifier.finalizeImageCapture(
                    data, isDirectPNG: isDirectPNG,
                    maxBytes: maxImageBytes, sensitive: sensitive)
            }

        case .pendingImageFile(let url, let sensitive):
            finishOnBackground(changeAtStart: countAtStart) {
                ClipboardClassifier.imageFromFile(
                    at: url, maxBytes: maxImageBytes, sensitive: sensitive)
            }

        case .skip(let reason):
            NSLog("ClipVault: skipped capture (%@)", reason)
        }
    }

    /// Runs heavy finalisation off-main and delivers to the store only if the
    /// clipboard hasn't been rewritten in the meantime. Delivery hops to the
    /// main queue first — `assumeIsolated` is only valid there (a background
    /// call traps, as a crash report once proved the hard way).
    private func finishOnBackground(changeAtStart: Int,
                                    _ work: @escaping () -> ClipCapture?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let capture = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let capture,
                          NSPasteboard.general.changeCount == changeAtStart else { return }
                    self.onCapture(capture)
                }
            }
        }
    }
}
