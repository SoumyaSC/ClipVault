import SwiftUI
import AppKit

extension Color {
    /// ClipVault indigo-violet brand accent.
    static let cvAccent = Color(red: 0.42, green: 0.36, blue: 0.95)
    static let cvAccentSoft = Color(red: 0.55, green: 0.48, blue: 1.00)
}

/// Formatting helpers shared across views.
enum CVFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ count: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(count))
    }

    static func count(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct HistoryView: View {

    @ObservedObject var viewModel: HistoryViewModel
    @FocusState private var searchFocused: Bool
    @State private var confirmClearAll = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if viewModel.showWelcome {
                WelcomeBanner(dismiss: { viewModel.dismissWelcome() })
            }
            content
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 384, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: viewModel.focusSearchToken) { _ in
            searchFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .medium))
                TextField("Search history", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        searchFocused ? Color.cvAccent.opacity(0.35) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            )

            HStack(spacing: 4) {
                ForEach(HistoryViewModel.Filter.allCases) { candidate in
                    FilterPill(
                        title: candidate.rawValue,
                        isSelected: viewModel.filter == candidate
                    ) {
                        viewModel.filter = candidate
                        viewModel.selectionIndex = 0
                    }
                }
                Spacer()
                Text("⌘⇧V")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let visible = viewModel.visibleItems
        if visible.isEmpty {
            EmptyStateView(viewModel: viewModel)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            ClipRowView(
                                item: item,
                                viewModel: viewModel,
                                isSelected: index == viewModel.selectionIndex
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.needsScroll) { needs in
                    guard needs, let item = viewModel.selectedItem else { return }
                    viewModel.needsScroll = false
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("ClipVault v\(appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text("·")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.4))

            let total = viewModel.context.store.items.count
            Text(total == 0 ? "no items" : "\(CVFormat.count(total)) item\(total == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.6))

            Spacer()

            Menu {
                Button("Clear Unpinned") {
                    viewModel.clearAll(includingPinned: false)
                }
                Button("Clear All…", role: .destructive) {
                    confirmClearAll = true
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Clear history")

            Button {
                viewModel.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")

            Button {
                NotificationCenter.default.post(name: .cvClosePopover, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Hide (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Delete all \(viewModel.context.store.items.filter(\.pinned).count > 0 ? "items including pinned ones" : "items")?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                viewModel.clearAll(includingPinned: true)
            }
            Button("Keep Pinned Items") {
                viewModel.clearAll(includingPinned: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Subcomponents

private struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected ? Color.cvAccent.opacity(0.13) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.cvAccent : Color.secondary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

struct HotkeyChip: View {
    let combo: String
    var onDark = false

    var body: some View {
        Text(combo)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(onDark ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(onDark ? Color.white.opacity(0.25) : Color.primary.opacity(0.09), lineWidth: 1)
            )
            .foregroundStyle(onDark ? Color.white.opacity(0.95) : Color.secondary)
    }
}

private struct WelcomeBanner: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.cvAccent)
            Text("Everything you copy lands here. ⌘⇧V opens this anywhere.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Text("Got it")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.cvAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct EmptyStateView: View {
    let viewModel: HistoryViewModel

    private var isFiltering: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.filter != .all
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isFiltering ? "magnifyingglass" : "doc.on.doc")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.cvAccent.opacity(0.55))
                .padding(.top, 110)

            Text(isFiltering ? "No matches" : "Nothing copied yet")
                .font(.system(size: 13, weight: .medium))

            Text(isFiltering
                 ? "Try a different search or filter."
                 : "Copy anything — it shows up here instantly.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !isFiltering {
                HStack(spacing: 12) {
                    LegendRow(chip: "↩", label: "copy")
                    LegendRow(chip: "⌘↩", label: "quick paste")
                    LegendRow(chip: "↑↓", label: "navigate")
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private struct LegendRow: View {
        let chip: String
        let label: String

        var body: some View {
            HStack(spacing: 4) {
                HotkeyChip(combo: chip)
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
