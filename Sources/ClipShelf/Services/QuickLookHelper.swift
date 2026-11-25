import AppKit
import ClipShelfCore
import Foundation
import QuickLookUI

@MainActor
public final class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookHelper()

    private var previewURL: URL?
    private var tempFileURL: URL?

    public func preview(item: ClipboardItem, storage: SQLiteStorage) {
        cleanupTemp()

        switch item.kind {
        case .image:
            if let filename = item.imageFilename {
                previewURL = storage.blobURL(for: filename)
            }
        case .file:
            if let first = item.filePaths.first {
                previewURL = URL(fileURLWithPath: first)
            }
        case .text, .link, .color:
            let content = item.plainText ?? item.urlString ?? item.colorHex ?? ""
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipShelf-Preview-\(item.id.uuidString).txt")
            try? content.write(to: tmp, atomically: true, encoding: .utf8)
            tempFileURL = tmp
            previewURL = tmp
        }

        guard previewURL != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    public func closeIfVisible() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        cleanupTemp()
    }

    private func cleanupTemp() {
        if let tempFileURL {
            try? FileManager.default.removeItem(at: tempFileURL)
            self.tempFileURL = nil
        }
    }

    public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}
