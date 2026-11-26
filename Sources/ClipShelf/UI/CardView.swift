import AppKit
import ClipShelfCore
import SwiftUI

struct CardView: View {
    let item: ClipboardItem
    let slotIndex: Int
    let isSelected: Bool
    let appIcon: NSImage?
    let previewImage: NSImage?
    let fileIcon: NSImage?
    let pinboards: [Pinboard]
    let onSelect: () -> Void
    let onPaste: (_ plainTextOnly: Bool) -> Void
    let onCopyOnly: () -> Void
    let onQuickLook: () -> Void
    let onTogglePin: (UUID) -> Void
    let onDelete: () -> Void

    static let cardWidth: CGFloat = 256
    static let cardHeight: CGFloat = 236

    var body: some View {
        VStack(spacing: 0) {
            headerBand
            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footerBar
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Color(red: 0.11, green: 0.115, blue: 0.125))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(0.09),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .shadow(
            color: Color.black.opacity(0.28),
            radius: 5,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(count: 2) {
            onSelect()
            onPaste(false)
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .contextMenu {
            Button("Paste") { onPaste(false) }
            Button("Paste as Plain Text") { onPaste(true) }
            Button("Copy to Clipboard") { onCopyOnly() }
            Button("Quick Look") { onQuickLook() }
            Divider()
            if !pinboards.isEmpty {
                Menu("Pin to Pinboard") {
                    ForEach(pinboards) { board in
                        let pinned = item.pinboardIDs.contains(board.id)
                        Button {
                            onTogglePin(board.id)
                        } label: {
                            Label(board.name, systemImage: pinned ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
                Divider()
            }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private var headerBand: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.customTitle ?? item.kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(RelativeTime.string(from: item.createdAt))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .frame(height: 54)
        .background(Color(hex: item.headerColorHex))
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch item.kind {
        case .text:
            Text(String((item.plainText ?? "").prefix(600)))
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineSpacing(2)
                .lineLimit(7)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 13)
                .padding(.top, 11)
                .padding(.bottom, 6)

        case .link:
            VStack(alignment: .leading, spacing: 6) {
                if let nsImage = previewImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.cardWidth, height: 112)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.linkTitle ?? item.urlString ?? "")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(previewImage == nil ? 5 : 2)
                }
                .padding(.horizontal, 13)
                .padding(.top, previewImage == nil ? 11 : 4)
            }

        case .image:
            if let nsImage = previewImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.cardWidth, height: 152)
                    .clipped()
            } else {
                Label("Image unavailable", systemImage: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .file:
            VStack(alignment: .leading, spacing: 8) {
                if let first = item.filePaths.first {
                    HStack(spacing: 10) {
                        if let fileIcon {
                            Image(nsImage: fileIcon)
                                .resizable()
                                .frame(width: 40, height: 40)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: first).lastPathComponent)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            if item.filePaths.count > 1 {
                                Text("+ \(item.filePaths.count - 1) more")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(first)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(3)
                }
            }
            .padding(13)

        case .color:
            ZStack {
                Color(hex: item.colorHex ?? "#0A84FF")
                Text((item.colorHex ?? "").uppercased())
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 6) {
            Text(item.footerMetadata)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if !item.pinboardIDs.isEmpty {
                HStack(spacing: 3) {
                    ForEach(item.pinboardIDs.prefix(3), id: \.self) { pid in
                        if let board = pinboards.first(where: { $0.id == pid }) {
                            Circle()
                                .fill(Color(hex: board.colorHex))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }

            HStack(spacing: 3) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9))
                Text("\(slotIndex)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 13)
        .frame(height: 30)
    }
}
