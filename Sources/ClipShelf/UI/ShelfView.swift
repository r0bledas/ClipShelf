import AppKit
import ClipShelfCore
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ShelfView: View {
    @ObservedObject var store: ClipboardStore
    let onPaste: (ClipboardItem, Bool) -> Void
    let onCopyOnly: (ClipboardItem) -> Void
    let onQuickLook: (ClipboardItem) -> Void
    let onOpenSettings: () -> Void
    let onOpenAbout: () -> Void
    let onOpenHelp: () -> Void
    let onQuit: () -> Void

    @FocusState private var searchFieldFocused: Bool
    @State private var showingNewPinboardPopover = false
    @State private var newPinboardName = ""
    @State private var newPinboardColor = PinboardPalette.colors[0].hex
    @State private var searchHovered = false
    @State private var plusHovered = false
    @State private var moreHovered = false

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.22)

            VStack(spacing: 12) {
                topBar
                    .padding(.top, 12)
                    .padding(.horizontal, 18)

                cardStrip
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.isSearching) { _, searching in
            if searching {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    searchFieldFocused = true
                }
            } else {
                searchFieldFocused = false
                store.searchQuery = ""
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        ZStack {
            // Centered controls: Search + History + Pinboards + Plus
            HStack(spacing: 8) {
                searchControl

                // History / Clipboard pill
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        store.activeTab = .clipboard
                        if store.isSearching {
                            store.isSearching = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .medium))
                        if !store.isSearching {
                            Text("Clipboard")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .foregroundStyle(store.activeTab == .clipboard ? .white : .white.opacity(0.7))
                    .padding(.horizontal, store.isSearching ? 9 : 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(store.activeTab == .clipboard ? Color.white.opacity(0.16) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help("Clipboard History")

                // Pinboards (shown when not searching)
                if !store.isSearching {
                    ForEach(store.pinboards) { board in
                        pinboardTab(board)
                    }

                    // Add Pinboard (+)
                    Button {
                        newPinboardName = ""
                        newPinboardColor = PinboardPalette.colors[store.pinboards.count % PinboardPalette.colors.count].hex
                        showingNewPinboardPopover = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(plusHovered ? 0.95 : 0.72))
                            .frame(width: 28, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(plusHovered ? Color.white.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in plusHovered = hovering }
                    .help("New Pinboard")
                    .popover(isPresented: $showingNewPinboardPopover, arrowEdge: .bottom) {
                        newPinboardPopover
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: store.isSearching)

            // Right-aligned status & ellipsis (...) menu
            HStack(spacing: 10) {
                Spacer()

                if store.settings.isPaused {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }

                Menu {
                    Button("About ClipShelf") { onOpenAbout() }
                    Divider()
                    Button("Settings…") { onOpenSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                    Button("Help") { onOpenHelp() }
                    Divider()
                    Button(store.settings.isPaused ? "Resume ClipShelf" : "Pause ClipShelf") {
                        store.settings.isPaused.toggle()
                    }
                    Divider()
                    Button("Quit ClipShelf") { onQuit() }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(moreHovered ? 0.95 : 0.75))
                        .frame(width: 28, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(moreHovered ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .onHover { hovering in moreHovered = hovering }
            }
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var searchControl: some View {
        if store.isSearching {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                TextField("Search", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($searchFieldFocused)
                    .frame(width: 210)
                    .onExitCommand {
                        store.isSearching = false
                    }

                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
                    )
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    store.isSearching = true
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(searchHovered ? 0.95 : 0.72))
                    .frame(width: 28, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(searchHovered ? Color.white.opacity(0.12) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in searchHovered = hovering }
            .help("Search (⌘F)")
        }
    }

    private func pinboardTab(_ board: Pinboard) -> some View {
        let isActive = store.activeTab == .pinboard(board.id)
        return Button {
            store.activeTab = .pinboard(board.id)
            store.selectedItemID = store.filteredItems.first?.id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: board.colorHex))
                    .frame(width: 8, height: 8)
                Text(board.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? .white : .white.opacity(0.75))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Menu("Color") {
                ForEach(PinboardPalette.colors, id: \.hex) { option in
                    Button(option.name) {
                        var updated = board
                        updated.colorHex = option.hex
                        store.updatePinboard(updated)
                    }
                }
            }
            Divider()
            Button("Delete Pinboard", role: .destructive) {
                store.deletePinboard(board)
            }
        }
    }

    private var newPinboardPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Pinboard")
                .font(.headline)

            TextField("Name", text: $newPinboardName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .onSubmit {
                    submitNewPinboard()
                }

            HStack(spacing: 8) {
                ForEach(PinboardPalette.colors, id: \.hex) { option in
                    Circle()
                        .fill(Color(hex: option.hex))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(.white, lineWidth: newPinboardColor == option.hex ? 2 : 0)
                        )
                        .onTapGesture {
                            newPinboardColor = option.hex
                        }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showingNewPinboardPopover = false
                }
                Button("Create") {
                    submitNewPinboard()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPinboardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    private func submitNewPinboard() {
        store.createPinboard(name: newPinboardName, colorHex: newPinboardColor)
        showingNewPinboardPopover = false
    }

    // MARK: - Card Strip

    private var cardStrip: some View {
        let items = store.filteredItems

        return Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    CardView(
                                        item: item,
                                        slotIndex: index + 1,
                                        isSelected: store.selectedItem?.id == item.id,
                                        appIcon: store.appIcon(for: item.sourceAppBundleID),
                                        storage: store.storage,
                                        pinboards: store.pinboards,
                                        onSelect: { store.selectedItemID = item.id },
                                        onPaste: { plainOnly in onPaste(item, plainOnly) },
                                        onCopyOnly: { onCopyOnly(item) },
                                        onQuickLook: { onQuickLook(item) },
                                        onTogglePin: { pid in store.togglePin(item: item, pinboardID: pid) },
                                        onDelete: { store.deleteItem(item) }
                                    )
                                    .id(item.id)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)
                        }
                        .onChange(of: store.selectedItemID) { _, newID in
                            if let newID {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo(newID, anchor: .center)
                                }
                            }
                        }

                        if items.count > 4 {
                            Button {
                                store.moveSelection(delta: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 28, height: 52)
                                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.isSearching ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text(store.isSearching ? "No matching items" : "No items yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text(store.isSearching ? "Try another search term" : "Copy text, links, images, or files to see them here.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
