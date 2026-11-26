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
    @Published public private(set) var filteredItems: [ClipboardItem] = []
    @Published public var pinboards: [Pinboard] = []
    @Published public var activeTab: ShelfTab = .clipboard {
        didSet {
            if oldValue != activeTab {
                rebuildFilteredItems()
            }
        }
    }
    @Published public var searchQuery: String = "" {
        didSet {
            if oldValue != searchQuery {
                rebuildFilteredItems()
            }
        }
    }
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
    private let blobImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        return cache
    }()
    private let fileIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        return cache
    }()
    private var searchIndex: [UUID: String] = [:]

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

    public var selectedItem: ClipboardItem? {
        guard let selectedItemID else { return filteredItems.first }
        return filteredItems.first(where: { $0.id == selectedItemID }) ?? filteredItems.first
    }

    private func buildSearchText(for item: ClipboardItem) -> String {
        var parts: [String] = []
        if let t = item.plainText { parts.append(t) }
        if let u = item.urlString { parts.append(u) }
        if let lt = item.linkTitle { parts.append(lt) }
        if let ct = item.customTitle { parts.append(ct) }
        if let app = item.sourceAppName { parts.append(app) }
        if let c = item.colorHex { parts.append(c) }
        if !item.filePaths.isEmpty { parts.append(item.filePaths.joined(separator: " ")) }
        parts.append(item.kind.displayName)
        return parts.joined(separator: " ").lowercased()
    }

    private func rebuildFilteredItems() {
        let base: [ClipboardItem]
        switch activeTab {
        case .clipboard:
            base = items
        case .pinboard(let pinID):
            base = items.filter { $0.pinboardIDs.contains(pinID) }
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filteredItems = base
        } else {
            let terms = trimmed.lowercased().split(separator: " ")
            filteredItems = base.filter { item in
                let haystack = searchIndex[item.id] ?? buildSearchText(for: item)
                return terms.allSatisfy { haystack.contains($0) }
            }
        }

        if let current = selectedItemID, filteredItems.contains(where: { $0.id == current }) {
            return
        }
        selectedItemID = filteredItems.first?.id
    }

    public func reloadAll() {
        self.pinboards = storage.fetchPinboards()
        let loaded = storage.fetchItems(limit: 500)
        self.items = loaded
        var newIndex: [UUID: String] = [:]
        newIndex.reserveCapacity(loaded.count)
        for item in loaded {
            newIndex[item.id] = buildSearchText(for: item)
        }
        self.searchIndex = newIndex
        rebuildFilteredItems()
    }

    public func handleCapturedItem(_ item: ClipboardItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: idx)
        }
        items.insert(item, at: 0)
        searchIndex[item.id] = buildSearchText(for: item)
        rebuildFilteredItems()
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
        searchIndex[itemID] = buildSearchText(for: items[idx])
        rebuildFilteredItems()
    }

    public func deleteItem(_ item: ClipboardItem) {
        let currentIdx = filteredItems.firstIndex(where: { $0.id == item.id })
        storage.deleteItem(item)
        items.removeAll(where: { $0.id == item.id })
        searchIndex.removeValue(forKey: item.id)
        rebuildFilteredItems()

        if let currentIdx, !filteredItems.isEmpty {
            let safeIdx = min(currentIdx, filteredItems.count - 1)
            selectedItemID = filteredItems[safeIdx].id
        } else {
            selectedItemID = filteredItems.first?.id
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
        rebuildFilteredItems()
    }

    public func renameItem(_ item: ClipboardItem, title: String?) {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = (clean?.isEmpty == true) ? nil : clean
        storage.updateCustomTitle(itemID: item.id, title: finalTitle)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].customTitle = finalTitle
            searchIndex[item.id] = buildSearchText(for: items[idx])
            rebuildFilteredItems()
        }
    }

    // MARK: - App Icon & Image Caching

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

    public func blobImage(named filename: String?) -> NSImage? {
        guard let filename else { return nil }
        let key = filename as NSString
        if let cached = blobImageCache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: storage.blobURL(for: filename)) else {
            return nil
        }
        blobImageCache.setObject(image, forKey: key)
        return image
    }

    public func fileIcon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        let key = path as NSString
        if let cached = fileIconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIconCache.setObject(icon, forKey: key)
        return icon
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
