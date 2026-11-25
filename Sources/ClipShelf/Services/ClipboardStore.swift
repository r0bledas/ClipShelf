import AppKit
import ClipShelfCore
import Foundation
import ServiceManagement

public enum ShelfTab: Equatable, Hashable {
    case clipboard
    case pinboard(UUID)
}

@MainActor
public final class ClipboardStore: ObservableObject {
    public let storage: SQLiteStorage

    @Published public var items: [ClipboardItem] = []
    @Published public var pinboards: [Pinboard] = []
    @Published public var activeTab: ShelfTab = .clipboard
    @Published public var searchQuery: String = ""
    @Published public var isSearching: Bool = false
    @Published public var selectedItemID: UUID?
    @Published public var settings: AppSettings {
        didSet {
            saveSettings()
            onSettingsChanged?(oldValue, settings)
        }
    }

    public var onSettingsChanged: ((AppSettings, AppSettings) -> Void)?

    private static let settingsKey = "com.clipshelf.settings.v1"
    private var appIconCache: [String: NSImage] = [:]

    public init(storage: SQLiteStorage) {
        self.storage = storage
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
        reloadAll()
        pruneIfNeeded()
    }

    public var filteredItems: [ClipboardItem] {
        let base: [ClipboardItem]
        switch activeTab {
        case .clipboard:
            base = items
        case .pinboard(let pinID):
            base = items.filter { $0.pinboardIDs.contains(pinID) }
        }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return base.filter { $0.matches(query: searchQuery) }
    }

    public var selectedItem: ClipboardItem? {
        guard let selectedItemID else { return filteredItems.first }
        return filteredItems.first(where: { $0.id == selectedItemID }) ?? filteredItems.first
    }

    public func reloadAll() {
        self.pinboards = storage.fetchPinboards()
        self.items = storage.fetchItems(limit: 500)
        if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = filteredItems.first?.id
        }
    }

    public func handleCapturedItem(_ item: ClipboardItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: idx)
        }
        items.insert(item, at: 0)
        if activeTab == .clipboard && searchQuery.isEmpty {
            selectedItemID = item.id
        }
    }

    public func handleLinkPreviewUpdated(itemID: UUID, title: String?, imageFilename: String?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].linkTitle = title
        if let imageFilename {
            items[idx].linkImageFilename = imageFilename
        }
    }

    public func deleteItem(_ item: ClipboardItem) {
        let currentList = filteredItems
        let currentIdx = currentList.firstIndex(where: { $0.id == item.id })
        storage.deleteItem(item)
        items.removeAll(where: { $0.id == item.id })

        let nextList = filteredItems
        if let currentIdx, !nextList.isEmpty {
            let safeIdx = min(currentIdx, nextList.count - 1)
            selectedItemID = nextList[safeIdx].id
        } else {
            selectedItemID = nextList.first?.id
        }
    }

    public func clearUnpinnedHistory() {
        storage.clearUnpinnedHistory()
        reloadAll()
    }

    public func moveSelection(delta: Int) {
        let list = filteredItems
        guard !list.isEmpty else { return }
        if let current = selectedItemID, let idx = list.firstIndex(where: { $0.id == current }) {
            let nextIdx = max(0, min(list.count - 1, idx + delta))
            selectedItemID = list[nextIdx].id
        } else {
            selectedItemID = list.first?.id
        }
    }

    public func selectItem(atIndex index: Int) -> ClipboardItem? {
        let list = filteredItems
        guard index >= 0, index < list.count else { return nil }
        let item = list[index]
        selectedItemID = item.id
        return item
    }

    // MARK: - Pinboards

    public func createPinboard(name: String, colorHex: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (pinboards.map(\.sortOrder).max() ?? -1) + 1
        let pinboard = Pinboard(name: trimmed, colorHex: colorHex, sortOrder: nextOrder)
        storage.savePinboard(pinboard)
        pinboards.append(pinboard)
        activeTab = .pinboard(pinboard.id)
        selectedItemID = filteredItems.first?.id
    }

    public func updatePinboard(_ pinboard: Pinboard) {
        storage.savePinboard(pinboard)
        if let idx = pinboards.firstIndex(where: { $0.id == pinboard.id }) {
            pinboards[idx] = pinboard
        }
    }

    public func deletePinboard(_ pinboard: Pinboard) {
        storage.deletePinboard(id: pinboard.id)
        pinboards.removeAll(where: { $0.id == pinboard.id })
        for idx in items.indices {
            items[idx].pinboardIDs.removeAll(where: { $0 == pinboard.id })
        }
        if activeTab == .pinboard(pinboard.id) {
            activeTab = .clipboard
        }
    }

    public func togglePin(item: ClipboardItem, pinboardID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if items[idx].pinboardIDs.contains(pinboardID) {
            storage.removeItem(item.id, fromPinboard: pinboardID)
            items[idx].pinboardIDs.removeAll(where: { $0 == pinboardID })
        } else {
            storage.assignItem(item.id, toPinboard: pinboardID)
            items[idx].pinboardIDs.append(pinboardID)
        }
    }

    public func renameItem(_ item: ClipboardItem, title: String?) {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = (clean?.isEmpty == true) ? nil : clean
        storage.updateCustomTitle(itemID: item.id, title: finalTitle)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].customTitle = finalTitle
        }
    }

    // MARK: - App Icon Lookup

    public func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = appIconCache[bundleID] {
            return cached
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            appIconCache[bundleID] = icon
            return icon
        }
        return nil
    }

    // MARK: - Settings & Login Item

    public func applyOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Best-effort when running unsigned/from build directory
        }
    }

    public func pruneIfNeeded() {
        guard let interval = settings.historyRetention.timeInterval else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        storage.pruneExpiredItems(olderThan: cutoff)
        reloadAll()
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}
