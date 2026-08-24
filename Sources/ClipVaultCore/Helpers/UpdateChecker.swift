import Foundation
import AppKit
import Combine

/// Checks GitHub Releases for a newer ClipVault and tells the user about it.
///
/// Deliberately *not* a self-installer. ClipVault ships ad-hoc signed, and
/// silently replacing an ad-hoc bundle from the network is exactly the kind of
/// trust hole this app shouldn't open; Homebrew (`brew upgrade --cask
/// clipvault`) covers the actual upgrade. This is the notification half.
///
/// The only network request ClipVault ever makes lives here: an unauthenticated
/// GET to api.github.com. Nothing is sent but the request itself, and the whole
/// thing is off when the user turns it off.
@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    struct Release: Equatable, Sendable {
        let version: String
        let page: URL
        let notes: String?
    }

    enum State: Equatable, Sendable {
        /// Never checked in this session.
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case failed(String)
        /// No release repository was stamped into the bundle (dev build).
        case unsupported
    }

    @Published private(set) var state: State = .idle

    private var timer: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private let session: URLSession

    /// `owner/repo` stamped in at build time (see Scripts/build_app.sh). A build
    /// with no real remote gets the placeholder and simply never checks, rather
    /// than silently querying somebody else's repository.
    let repository: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    init(session: URLSession = .shared,
         repository: String? = Bundle.main.object(forInfoDictionaryKey: "CVUpdateRepository") as? String) {
        self.session = session
        if let repository, !repository.isEmpty, !repository.hasPrefix("OWNER/") {
            self.repository = repository
        } else {
            self.repository = nil
        }
        if self.repository == nil {
            state = .unsupported
        }
    }

    /// Called once at launch. Checks now and daily thereafter, and reacts to the
    /// preference being switched off/on without needing a relaunch.
    func start(settings: SettingsStore) {
        settingsObserver = settings.$checkForUpdates
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.resumeSchedule()
                } else {
                    self.suspendSchedule()
                }
            }
    }

    private func resumeSchedule() {
        guard repository != nil else { return }
        check()
        timer?.cancel()
        timer = Timer.publish(every: 86_400, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.check() }
    }

    private func suspendSchedule() {
        timer?.cancel()
        timer = nil
        // A previously found update stops nagging once checking is turned off.
        if case .available = state { state = .idle }
    }

    /// One-shot check. Safe to call from a "Check Now" button.
    func check() {
        guard let repository else {
            state = .unsupported
            return
        }
        guard state != .checking else { return }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            state = .failed("Bad repository configuration")
            return
        }

        state = .checking
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClipVault/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let current = currentVersion
        session.dataTask(with: request) { data, response, error in
            let outcome = Self.interpret(data: data, response: response, error: error, current: current)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.state = outcome }
            }
        }.resume()
    }

    // MARK: - Pure logic (unit-tested)

    /// Turns a raw GitHub response into the state the UI should show.
    nonisolated static func interpret(data: Data?, response: URLResponse?, error: Error?, current: String) -> State {
        if let error {
            return .failed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed("No response from GitHub")
        }
        guard http.statusCode == 200 else {
            // 404 is the normal answer for a repo with no published release yet.
            return http.statusCode == 404
                ? .upToDate(checkedAt: Date())
                : .failed("GitHub returned \(http.statusCode)")
        }
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failed("Unreadable response from GitHub")
        }
        guard let release = payload.release else {
            return .upToDate(checkedAt: Date())
        }
        guard isVersion(release.version, newerThan: current) else {
            return .upToDate(checkedAt: Date())
        }
        return .available(release)
    }

    /// Semver-ish comparison over the leading numeric components.
    ///
    /// A pre-release suffix (`1.1.0-beta.1`) is treated as *older* than the same
    /// numbers without one, per semver — so a beta tag never nags stable users.
    nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let (candidateNumbers, candidateIsPrerelease) = parse(candidate)
        let (installedNumbers, installedIsPrerelease) = parse(installed)

        for index in 0..<max(candidateNumbers.count, installedNumbers.count) {
            let a = index < candidateNumbers.count ? candidateNumbers[index] : 0
            let b = index < installedNumbers.count ? installedNumbers[index] : 0
            if a != b { return a > b }
        }
        // Same numbers: a release beats a pre-release, nothing else moves.
        return installedIsPrerelease && !candidateIsPrerelease
    }

    /// "v1.2.3-beta.1" → ([1, 2, 3], true)
    nonisolated private static func parse(_ version: String) -> ([Int], Bool) {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let isPrerelease = text.contains("-")
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        return (numbers.isEmpty ? [0] : numbers, isPrerelease)
    }

    // MARK: - Decoding

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease
        }

        /// Drafts and pre-releases never surface as updates.
        var release: Release? {
            guard draft != true, prerelease != true else { return nil }
            guard let page = URL(string: htmlURL) else { return nil }
            var version = tagName
            if version.hasPrefix("v") { version.removeFirst() }
            guard !version.isEmpty else { return nil }
            let notes = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Release(version: version, page: page, notes: (notes?.isEmpty == false) ? notes : nil)
        }
    }
}
