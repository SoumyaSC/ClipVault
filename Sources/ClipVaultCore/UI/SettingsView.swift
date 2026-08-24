import SwiftUI
import AppKit

struct SettingsView: View {

    enum Tab: String, CaseIterable {
        case general, history, security, advanced
    }

    @State private var selection: Tab

    init(initialTab: Tab = .general) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "switch.2") }
                .tag(Tab.general)
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            SecuritySettingsTab()
                .tabItem { Label("Security", systemImage: "hand.raised") }
                .tag(Tab.security)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(Tab.advanced)
        }
        .frame(width: 560, height: 500)
        .padding(4)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppContext.shared.settings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch ClipVault at login", isOn: $settings.launchAtLogin)
                Toggle("Show ClipVault in the Dock", isOn: $settings.dockIconEnabled)
                Text("With the Dock icon, clicking it opens your history — handy if a crowded menu bar hides the status icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Panel") {
                Toggle("Open with ⌘⇧V from anywhere", isOn: $settings.hotKeyEnabled)
                Toggle("Close panel after copying an item", isOn: $settings.autoCloseOnCopy)
            }
            Section("Feedback") {
                Toggle("Haptic tick on copy (Force Touch trackpads)", isOn: $settings.hapticsEnabled)
                Text("You'll feel a subtle tick when an item is copied back — the same feedback as a calendar snap. On Macs without a Force Touch trackpad this is a silent no-op. ClipVault plays no sounds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // Sync with reality — the user may have flipped this in System
            // Settings. Runs after the first render (never mutate observed
            // state during a view update), and only when macOS gives a
            // trustworthy answer; see LoginItem.reportedState.
            if let actual = LoginItem.reportedState, settings.launchAtLogin != actual {
                settings.launchAtLogin = actual
            }
        }
    }
}

// MARK: - History

struct HistorySettingsTab: View {
    @ObservedObject private var settings = AppContext.shared.settings
    @State private var storageUsed = "…"
    @State private var lastPurgeNote: String?

    var body: some View {
        Form {
            Section("Capacity") {
                Stepper(value: $settings.maxItems, in: 50...1000, step: 50) {
                    Text("Keep the last **\(CVFormat.count(settings.maxItems))** items")
                }
            }

            Section("Images") {
                Picker("Automatically purge images older than", selection: $settings.imageRetentionDays) {
                    ForEach(SettingsStore.retentionOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
            }

            Section("Storage") {
                HStack {
                    Text(storageUsed)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Purge Expired Images Now") {
                        let removed = AppContext.shared.store.purgeExpiredImages()
                        lastPurgeNote = removed == 0 ? "Nothing to purge." : "Removed \(removed) image\(removed == 1 ? "" : "s")."
                        refreshStorage()
                    }
                    Button("Open Data Folder") {
                        NSWorkspace.shared.open(AppContext.shared.store.directory)
                    }
                }
                if let note = lastPurgeNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStorage)
    }

    private func refreshStorage() {
        storageUsed = "Calculating…"
        let directory = AppContext.shared.store.directory
        DispatchQueue.global(qos: .utility).async {
            let bytes = Self.folderSize(directory)
            let text = "Storage used: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            DispatchQueue.main.async { storageUsed = text }
        }
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Security

struct SecuritySettingsTab: View {
    @ObservedObject private var settings = AppContext.shared.settings
    @State private var newBundleID = ""

    var body: some View {
        Form {
            Section("Sensitive Content") {
                Toggle("Never record copies from password managers", isOn: $settings.skipConcealed)
                Text("1Password, Bitwarden, KeePassXC and friends mark their copies as concealed; ClipVault honours this signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hide sensitive items behind •••• in the list", isOn: $settings.maskSensitive)
                Text("Applies when concealed capture is allowed above — contents stay hidden until copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Ignore short numeric codes (likely OTP)", isOn: $settings.skipShortNumeric)
            }

            Section("Apps to Ignore") {
                Text("Copies made inside these apps are never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(settings.ignoredBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            settings.ignoredBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBundle)
                    Button("Add", action: addBundle)
                    Button("Restore Defaults") {
                        settings.ignoredBundleIDs = SettingsStore.defaultIgnoredApps
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addBundle() {
        let trimmed = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !settings.ignoredBundleIDs.contains(trimmed) else { return }
        settings.ignoredBundleIDs.append(trimmed)
        newBundleID = ""
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @ObservedObject private var settings = AppContext.shared.settings
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var accessibilityGranted = QuickPaster.isTrusted

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Circle()
                        .fill(accessibilityGranted ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accessibilityGranted ? "Quick Paste is ready" : "Accessibility permission needed for Quick Paste")
                            .font(.system(size: 12, weight: .medium))
                        Text("Required only if you use double-click / ⌘↩ direct pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(accessibilityGranted ? "Re-check" : "Grant / Open Settings") {
                        if !accessibilityGranted {
                            QuickPaster.openSystemAccessibilityPane()
                        }
                        // Re-check after a beat so the user sees state flip.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            accessibilityGranted = QuickPaster.isTrusted
                        }
                    }
                }
            }

            Section("Updates") {
                HStack(spacing: 8) {
                    updateStatusLine
                    Spacer()
                    if case .available(let release) = updater.state {
                        Button("What's New") { NSWorkspace.shared.open(release.page) }
                    }
                    Button("Check Now") { updater.check() }
                        .disabled(updater.state == .checking || updater.state == .unsupported)
                }
                Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
                Text("A once-a-day request to api.github.com asking for the latest release number — the only network call ClipVault makes. Install updates with `brew upgrade --cask clipvault`, or from the release page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Show Welcome Banner Again") {
                    settings.welcomeShown = false
                }
            }

            Section("About") {
                LabeledData(label: "Version", value: appVersion)
                LabeledData(label: "Data location", value: AppContext.shared.store.directory.path)
            }
        }
        .formStyle(.grouped)
        .onAppear { accessibilityGranted = QuickPaster.isTrusted }
    }

    /// Marketing version, monotonic build number, and the source commit when the
    /// build came from a git checkout — the three things a bug report needs.
    @ViewBuilder
    private var updateStatusLine: some View {
        switch updater.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 9, height: 9)
                Text("ClipVault \(updater.currentVersion) is the latest release")
            }
        case .available(let release):
            HStack(spacing: 6) {
                Circle().fill(Color.cvAccent).frame(width: 9, height: 9)
                Text("Version \(release.version) is available")
                    .font(.system(size: 12, weight: .medium))
            }
        case .failed(let reason):
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 9, height: 9)
                Text("Couldn't check: \(reason)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .unsupported:
            Text("Update checks are off in local builds").foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let commit = Bundle.main.object(forInfoDictionaryKey: "CVSourceCommit") as? String
        var text = "\(version) (\(build))"
        if let commit, commit != "unknown", !commit.isEmpty {
            text += " · \(commit)"
        }
        return text
    }
}

private struct LabeledData: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
