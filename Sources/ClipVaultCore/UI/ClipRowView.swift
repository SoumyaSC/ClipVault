import SwiftUI
import AppKit

/// One history entry — deliberately quiet.
///
/// Design rules:
/// - For text, *the content is the icon*: no leading glyphs, no badges.
/// - Images speak through their real thumbnail.
/// - Meta is a single tertiary whisper: time + essential facts only.
/// - Actions appear only on hover, inline at the meta line's trailing edge.
struct ClipRowView: View {

    let item: ClipItem
    let viewModel: HistoryViewModel
    let isSelected: Bool

    @State private var hovering = false

    private var isFlash: Bool { viewModel.flashID == item.id }
    private var isFlashError: Bool { isFlash && viewModel.flashIsError }
    private var isMasked: Bool { item.sensitive && viewModel.settings.maskSensitive }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if item.kind == .image, let thumbnail = viewModel.thumbnail(for: item) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                previewLine
                    .lineLimit(2)

                HStack(spacing: 8) {
                    metaLine
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 6)

                    if isFlash {
                        resultBadge
                            .transition(.opacity)
                    } else if hovering {
                        actionBar
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowFill)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.select(itemID: item.id)
            viewModel.copy(item)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { viewModel.copy(item) }.keyboardShortcut(.return, modifiers: [])
            Button("Quick Paste") { viewModel.quickPaste(item) }.keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button(item.pinned ? "Unpin" : "Pin") { viewModel.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { viewModel.delete(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Copies on click; press ⌘↩ for Quick Paste")
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isFlash)
    }

    // MARK: - Content

    @ViewBuilder
    private var previewLine: some View {
        if isMasked {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Text("••••••••")
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            switch item.kind {
            case .text:
                Text(item.textPreview ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.88))
            case .image:
                Text("Image")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.88))
            case .files:
                Text(fileSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.88))
            }
        }
    }

    private var fileSummary: String {
        guard let paths = item.filePaths, !paths.isEmpty else { return "Files" }
        let names = paths.map { ($0 as NSString).lastPathComponent }
        if names.count <= 2 {
            return names.joined(separator: ", ")
        }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.cvAccent.opacity(0.85))
            }
            Text(CVFormat.relative(item.createdAt))

            if !isMasked {
                if let detail = metaDetail {
                    Text("·")
                    Text(detail)
                }
            } else {
                Text("· hidden")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Color.secondary.opacity(0.75))
    }

    private var metaDetail: String? {
        switch item.kind {
        case .text:
            return nil   // the preview already says everything worth saying
        case .image:
            var parts: [String] = []
            if let w = item.pixelWidth, let h = item.pixelHeight {
                parts.append("\(w)×\(h)")
            }
            parts.append(CVFormat.bytes(item.byteSize))
            return parts.joined(separator: " · ")
        case .files:
            let n = item.filePaths?.count ?? 0
            return n == 1 ? "1 file" : "\(n) files"
        }
    }

    // MARK: - Result badge / hover actions

    private var resultBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: isFlashError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isFlashError ? Color.red.opacity(0.85) : Color.green.opacity(0.85))
            Text(isFlashError ? "Failed" : "Copied")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isFlashError ? Color.red.opacity(0.85) : Color.green.opacity(0.85))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 11) {
            Button {
                viewModel.togglePin(item)
            } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(QuietActionStyle(active: item.pinned))
            .help(item.pinned ? "Unpin" : "Pin to top")

            Button {
                viewModel.quickPaste(item)
            } label: {
                Image(systemName: "clipboard")
            }
            .buttonStyle(QuietActionStyle(active: false))
            .help("Quick Paste (⌘↩)")

            Button(role: .destructive) {
                viewModel.delete(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(QuietActionStyle(active: false))
            .help("Delete")
        }
    }

    // MARK: - States

    private var rowFill: Color {
        if isFlash { return isFlashError ? Color.red.opacity(0.06) : Color.green.opacity(0.07) }
        if isSelected { return Color.cvAccent.opacity(0.10) }
        if hovering { return Color.primary.opacity(0.035) }
        return Color.clear
    }

    private var accessibilitySummary: String {
        switch item.kind {
        case .text:
            return isMasked ? "Sensitive text item, hidden" : "Text item: \(item.textPreview?.prefix(60) ?? "")"
        case .image:
            return "Image item, \(item.pixelWidth ?? 0) by \(item.pixelHeight ?? 0) pixels"
        case .files:
            return "File item"
        }
    }
}

/// Borderless inline glyph — appears on hover, brightens on press. No chrome.
struct QuietActionStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(
                configuration.isPressed ? Color.cvAccent
                : active ? Color.cvAccent.opacity(0.85)
                : Color.secondary.opacity(0.8)
            )
            .opacity(configuration.isPressed ? 1.0 : 0.85)
    }
}
