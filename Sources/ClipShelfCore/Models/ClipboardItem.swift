import Foundation

public enum ClipboardItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case link
    case image
    case file
    case color

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        }
    }
}

public struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ClipboardItemKind
    public var plainText: String?
    public var rtfData: Data?
    public var urlString: String?
    public var imageFilename: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var filePaths: [String]
    public var colorHex: String?
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var headerColorHex: String
    public var createdAt: Date
    public var contentHash: String
    public var linkTitle: String?
    public var linkImageFilename: String?
    public var customTitle: String?
    public var pinboardIDs: [UUID]

    public init(
        id: UUID = UUID(),
        kind: ClipboardItemKind,
        plainText: String? = nil,
        rtfData: Data? = nil,
        urlString: String? = nil,
        imageFilename: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        filePaths: [String] = [],
        colorHex: String? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        headerColorHex: String = "#3A3D42",
        createdAt: Date = Date(),
        contentHash: String,
        linkTitle: String? = nil,
        linkImageFilename: String? = nil,
        customTitle: String? = nil,
        pinboardIDs: [UUID] = []
    ) {
        self.id = id
        self.kind = kind
        self.plainText = plainText
        self.rtfData = rtfData
        self.urlString = urlString
        self.imageFilename = imageFilename
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.filePaths = filePaths
        self.colorHex = colorHex
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.headerColorHex = headerColorHex
        self.createdAt = createdAt
        self.contentHash = contentHash
        self.linkTitle = linkTitle
        self.linkImageFilename = linkImageFilename
        self.customTitle = customTitle
        self.pinboardIDs = pinboardIDs
    }

    public var characterCount: Int {
        plainText?.count ?? urlString?.count ?? 0
    }

    public var hostDisplay: String? {
        guard let urlString, let url = URL(string: urlString), let host = url.host else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public var footerMetadata: String {
        switch kind {
        case .text:
            let count = characterCount
            return count == 1 ? "1 character" : "\(count) characters"
        case .link:
            return hostDisplay ?? urlString ?? "Link"
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "\(w) × \(h)"
            }
            return "Image"
        case .file:
            if filePaths.count == 1, let first = filePaths.first {
                return URL(fileURLWithPath: first).lastPathComponent
            }
            return "\(filePaths.count) files"
        case .color:
            return colorHex?.uppercased() ?? "Color"
        }
    }

    public func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let terms = trimmed.lowercased().split(separator: " ")
        let searchable = [
            plainText,
            urlString,
            linkTitle,
            customTitle,
            sourceAppName,
            colorHex,
            filePaths.joined(separator: " "),
            kind.displayName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return terms.allSatisfy { searchable.contains($0) }
    }
}

public struct Pinboard: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#0A84FF",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public enum PinboardPalette {
    public static let colors: [(name: String, hex: String)] = [
        ("Blue", "#0A84FF"),
        ("Purple", "#BF5AF2"),
        ("Pink", "#FF375F"),
        ("Red", "#FF453A"),
        ("Orange", "#FF9F0A"),
        ("Yellow", "#FFD60A"),
        ("Green", "#30D158"),
        ("Teal", "#40C8E0"),
        ("Graphite", "#8E8E93")
    ]
}

public struct ShortcutSpec: Codable, Equatable, Sendable {
    /// Carbon virtual key code (e.g., 9 = V)
    public var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey)
    public var modifiers: UInt32
    /// Human-readable display string (e.g., "⇧⌘V")
    public var displayString: String

    public init(keyCode: UInt32, modifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }

    /// Default: ⇧⌘V (keyCode 9 = kVK_ANSI_V, cmdKey 256 + shiftKey 512 = 768)
    public static let defaultActivate = ShortcutSpec(keyCode: 9, modifiers: 768, displayString: "⇧⌘V")
}

public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case forever = "Forever"

    public var timeInterval: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 86_400 * 7
        case .month: return 86_400 * 30
        case .forever: return nil
        }
    }
}

public struct IgnoredApp: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public static let defaults: [IgnoredApp] = [
        IgnoredApp(bundleID: "com.apple.Passwords", name: "Passwords"),
        IgnoredApp(bundleID: "com.apple.keychainaccess", name: "Keychain Access")
    ]
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var openAtLogin: Bool
    public var showInMenuBar: Bool
    public var soundEffectsEnabled: Bool
    public var isPaused: Bool
    public var historyRetention: HistoryRetention
    public var activateShortcut: ShortcutSpec
    public var ignoreConfidential: Bool
    public var ignoreTransient: Bool
    public var generateLinkPreviews: Bool
    public var ignoredApps: [IgnoredApp]

    public init(
        openAtLogin: Bool = false,
        showInMenuBar: Bool = true,
        soundEffectsEnabled: Bool = true,
        isPaused: Bool = false,
        historyRetention: HistoryRetention = .month,
        activateShortcut: ShortcutSpec = .defaultActivate,
        ignoreConfidential: Bool = true,
        ignoreTransient: Bool = true,
        generateLinkPreviews: Bool = true,
        ignoredApps: [IgnoredApp] = IgnoredApp.defaults
    ) {
        self.openAtLogin = openAtLogin
        self.showInMenuBar = showInMenuBar
        self.soundEffectsEnabled = soundEffectsEnabled
        self.isPaused = isPaused
        self.historyRetention = historyRetention
        self.activateShortcut = activateShortcut
        self.ignoreConfidential = ignoreConfidential
        self.ignoreTransient = ignoreTransient
        self.generateLinkPreviews = generateLinkPreviews
        self.ignoredApps = ignoredApps
    }
}
