import AppKit
import ClipShelfCore
import CryptoKit
import Foundation
import LinkPresentation

@MainActor
public final class ClipboardWatcher {
    private let storage: SQLiteStorage
    private let settingsProvider: () -> AppSettings
    private let onCapture: (ClipboardItem) -> Void
    private let onLinkPreviewUpdated: (UUID, String?, String?) -> Void

    private var timer: Timer?
    private var lastChangeCount: Int
    private var appColorCache: [String: String] = [:]

    public init(
        storage: SQLiteStorage,
        settingsProvider: @escaping () -> AppSettings,
        onCapture: @escaping (ClipboardItem) -> Void,
        onLinkPreviewUpdated: @escaping (UUID, String?, String?) -> Void
    ) {
        self.storage = storage
        self.settingsProvider = settingsProvider
        self.onCapture = onCapture
        self.onLinkPreviewUpdated = onLinkPreviewUpdated
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let settings = settingsProvider()
        let rawTypes = Set((pb.types ?? []).map { $0.rawValue })
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier
        let appName = frontApp?.localizedName

        if ClipboardRules.shouldIgnore(pasteboardTypes: rawTypes, sourceBundleID: bundleID, settings: settings) {
            return
        }

        let headerColor = cachedHeaderColor(for: frontApp)

        guard let item = extractItem(
            from: pb,
            sourceBundleID: bundleID,
            sourceAppName: appName,
            headerColorHex: headerColor
        ) else {
            return
        }

        let persisted = storage.upsertItem(item)
        SoundEffectPlayer.shared.playCopy(enabled: settings.soundEffectsEnabled)
        onCapture(persisted)

        if persisted.kind == .link,
           settings.generateLinkPreviews,
           persisted.linkTitle == nil,
           let urlStr = persisted.urlString,
           let url = URL(string: urlStr) {
            fetchLinkMetadata(for: persisted.id, url: url)
        }
    }

    private func cachedHeaderColor(for app: NSRunningApplication?) -> String {
        guard let app else { return ColorExtractor.fallbackHex }
        let key = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        if let cached = appColorCache[key] {
            return cached
        }
        if let bundleID = app.bundleIdentifier,
           let storedHex = storage.fetchLatestHeaderColor(forBundleID: bundleID) {
            appColorCache[key] = storedHex
            return storedHex
        }
        let hex = ColorExtractor.dominantHeaderColorHex(from: app.icon)
        appColorCache[key] = hex
        return hex
    }

    private func extractItem(
        from pb: NSPasteboard,
        sourceBundleID: String?,
        sourceAppName: String?,
        headerColorHex: String
    ) -> ClipboardItem? {
        // 1. Files (file URLs)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }
            let hash = sha256("file:" + paths.joined(separator: "\n"))
            return ClipboardItem(
                kind: .file,
                plainText: paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "),
                filePaths: paths,
                sourceAppBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                headerColorHex: headerColorHex,
                contentHash: hash
            )
        }

        // 2. Images (PNG / TIFF) when no plain text string is primary
        let hasText = (pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if !hasText, let image = NSImage(pasteboard: pb), let pngData = pngRepresentation(of: image) {
            let hash = sha256(pngData)
            if let filename = try? storage.saveBlob(pngData, fileExtension: "png") {
                let rep = image.representations.first
                let width = rep?.pixelsWide ?? Int(image.size.width)
                let height = rep?.pixelsHigh ?? Int(image.size.height)
                return ClipboardItem(
                    kind: .image,
                    imageFilename: filename,
                    imageWidth: width > 0 ? width : nil,
                    imageHeight: height > 0 ? height : nil,
                    sourceAppBundleID: sourceBundleID,
                    sourceAppName: sourceAppName,
                    headerColorHex: headerColorHex,
                    contentHash: hash
                )
            }
        }

        // 3. Text / Link / Color
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let rtfData = pb.data(forType: .rtf)

            if let hex = ClipboardRules.normalizedHexColor(from: trimmed) {
                return ClipboardItem(
                    kind: .color,
                    plainText: trimmed,
                    colorHex: hex,
                    sourceAppBundleID: sourceBundleID,
                    sourceAppName: sourceAppName,
                    headerColorHex: hex,
                    contentHash: sha256("color:" + hex)
                )
            }

            if let url = ClipboardRules.normalizedWebURL(from: trimmed) {
                return ClipboardItem(
                    kind: .link,
                    plainText: trimmed,
                    urlString: url.absoluteString,
                    sourceAppBundleID: sourceBundleID,
                    sourceAppName: sourceAppName,
                    headerColorHex: headerColorHex,
                    contentHash: sha256("link:" + url.absoluteString)
                )
            }

            return ClipboardItem(
                kind: .text,
                plainText: text,
                rtfData: rtfData,
                sourceAppBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                headerColorHex: headerColorHex,
                contentHash: sha256("text:" + text)
            )
        }

        return nil
    }

    private func pngRepresentation(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func fetchLinkMetadata(for itemID: UUID, url: URL) {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let storageRef = self.storage

        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            guard let metadata else { return }
            let title = metadata.title

            if let imageProvider = metadata.imageProvider ?? metadata.iconProvider {
                let capturedSelf = self
                imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    var savedFilename: String?
                    if let data,
                       let img = NSImage(data: data),
                       let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                        savedFilename = try? storageRef.saveBlob(jpg, fileExtension: "jpg")
                    }
                    storageRef.updateLinkPreview(itemID: itemID, title: title, imageFilename: savedFilename)
                    Task { @MainActor in
                        capturedSelf?.onLinkPreviewUpdated(itemID, title, savedFilename)
                    }
                }
            } else if title != nil {
                storageRef.updateLinkPreview(itemID: itemID, title: title, imageFilename: nil)
                Task { @MainActor in
                    self?.onLinkPreviewUpdated(itemID, title, nil)
                }
            }
        }
    }

    private func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
