import Foundation
import Combine

/// Configuration values the store/monitor need, resolved from settings at call time.
struct HistoryConfig {
    var maxItems: Int
    var imageRetentionDays: Int
}

/// The slice of `UserDefaults` that `SettingsStore` actually needs. Declaring it
/// lets tests hand in an in-memory double instead of a real preferences suite —
/// a suite would leave plists behind in ~/Library/Preferences on every run,
/// because cfprefsd flushes its cache after the test process exits.
protocol SettingsDefaults: AnyObject {
    func object(forKey key: String) -> Any?
    func bool(forKey key: String) -> Bool
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsDefaults {}

/// Central user preferences. All persistence goes through UserDefaults.
/// Views observe this object; services read it directly on the main thread.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(defaults: SettingsStore.defaultBackingStore())

    /// `UserDefaults.standard`, unless `CV_DEFAULTS_SUITE` names a scratch
    /// suite — the settings counterpart to `CV_DATA_DIR`; see ClipStore.
    static func defaultBackingStore() -> SettingsDefaults {
        if let suite = ProcessInfo.processInfo.environment["CV_DEFAULTS_SUITE"],
           !suite.isEmpty,
           let scratch = UserDefaults(suiteName: suite) {
            return scratch
        }
        return UserDefaults.standard
    }

    private let defaults: SettingsDefaults

    private enum Key {
        static let launchAtLogin      = "cv.launchAtLogin"
        static let hotKeyEnabled      = "cv.hotKeyEnabled"
        static let hapticsEnabled     = "cv.hapticsEnabled"
        static let maxItems           = "cv.maxItems"
        static let imageRetentionDays = "cv.imageRetentionDays"
        static let skipConcealed      = "cv.skipConcealed"
        static let maskSensitive      = "cv.maskSensitive"
        static let skipShortNumeric   = "cv.skipShortNumeric"
        static let ignoredApps        = "cv.ignoredBundleIDs"
        static let welcomeShown       = "cv.welcomeShown"
        static let autoCloseOnCopy    = "cv.autoCloseOnCopy"
        static let dockIconEnabled    = "cv.dockIconEnabled"
        static let checkForUpdates    = "cv.checkForUpdates"
    }

    /// Single source of truth for the image-retention choices: the History tab
    /// renders these, and `init` validates the persisted value against them.
    static let retentionOptions: [(days: Int, label: String)] = [
        (7, "7 days"),
        (30, "30 days"),
        (90, "90 days"),
        (365, "1 year"),
        (0, "Never expire automatically"),
    ]

    static var retentionChoices: [Int] { retentionOptions.map(\.days) }

    /// Bundle IDs of well-known password managers / secret stores, used as defaults.
    static let defaultIgnoredApps: [String] = [
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.lastpassdesktop",
        "org.keepassxc.keepassxc",
        "com.keepassx.keepassx",
        "com.dashlane.dashlane",
        "com.apple.keychainaccess",
    ]

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Key.hotKeyEnabled) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }
    /// Upper bound for retained items (unpinned). Range 50...1000.
    @Published var maxItems: Int {
        didSet { defaults.set(maxItems, forKey: Key.maxItems) }
    }
    /// Images older than this many days are purged automatically. 0 = keep until evicted.
    @Published var imageRetentionDays: Int {
        didSet { defaults.set(imageRetentionDays, forKey: Key.imageRetentionDays) }
    }
    /// Never record copies flagged as concealed (password managers).
    @Published var skipConcealed: Bool {
        didSet { defaults.set(skipConcealed, forKey: Key.skipConcealed) }
    }
    /// Show captured sensitive items masked (••••) in the list.
    @Published var maskSensitive: Bool {
        didSet { defaults.set(maskSensitive, forKey: Key.maskSensitive) }
    }
    /// Ignore short numeric-only strings (likely OTP codes).
    @Published var skipShortNumeric: Bool {
        didSet { defaults.set(skipShortNumeric, forKey: Key.skipShortNumeric) }
    }
    /// Copies originating from these bundle IDs are never recorded.
    @Published var ignoredBundleIDs: [String] {
        didSet { defaults.set(ignoredBundleIDs, forKey: Key.ignoredApps) }
    }
    @Published var welcomeShown: Bool {
        didSet { defaults.set(welcomeShown, forKey: Key.welcomeShown) }
    }
    /// Close the panel automatically after a plain click-to-copy.
    @Published var autoCloseOnCopy: Bool {
        didSet { defaults.set(autoCloseOnCopy, forKey: Key.autoCloseOnCopy) }
    }
    /// Also present ClipVault in the Dock (escape hatch for crowded menu bars).
    @Published var dockIconEnabled: Bool {
        didSet { defaults.set(dockIconEnabled, forKey: Key.dockIconEnabled) }
    }
    /// Ask GitHub once a day whether a newer release exists. The only network
    /// request ClipVault makes; see UpdateChecker.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }

    init(defaults: SettingsDefaults = UserDefaults.standard) {
        self.defaults = defaults
        launchAtLogin      = defaults.bool(forKey: Key.launchAtLogin)
        hotKeyEnabled      = defaults.object(forKey: Key.hotKeyEnabled) as? Bool ?? true
        hapticsEnabled     = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        maxItems           = defaults.object(forKey: Key.maxItems) as? Int ?? 200
        imageRetentionDays = defaults.object(forKey: Key.imageRetentionDays) as? Int ?? 30
        skipConcealed      = defaults.object(forKey: Key.skipConcealed) as? Bool ?? true
        maskSensitive      = defaults.object(forKey: Key.maskSensitive) as? Bool ?? true
        skipShortNumeric   = defaults.object(forKey: Key.skipShortNumeric) as? Bool ?? false
        ignoredBundleIDs   = defaults.stringArray(forKey: Key.ignoredApps) ?? SettingsStore.defaultIgnoredApps
        welcomeShown       = defaults.bool(forKey: Key.welcomeShown)
        autoCloseOnCopy    = defaults.object(forKey: Key.autoCloseOnCopy) as? Bool ?? true
        dockIconEnabled    = defaults.bool(forKey: Key.dockIconEnabled)
        checkForUpdates    = defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true

        maxItems           = min(max(maxItems, 50), 1000)
        // 0 means "never expire automatically" and is a real choice in the
        // History tab — it must survive a relaunch like any other value.
        imageRetentionDays = SettingsStore.retentionChoices.contains(imageRetentionDays) ? imageRetentionDays : 30
    }

    var historyConfig: HistoryConfig {
        HistoryConfig(maxItems: maxItems, imageRetentionDays: imageRetentionDays)
    }
}
