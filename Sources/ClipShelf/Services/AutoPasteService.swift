import AppKit
import ApplicationServices
import Carbon
import ClipShelfCore
import Foundation

@MainActor
public final class AutoPasteService {
    public static let shared = AutoPasteService()

    private init() {}

    public func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Writes `item` to the system pasteboard without triggering a duplicate capture.
    public func copyToPasteboard(
        _ item: ClipboardItem,
        storage: SQLiteStorage,
        plainTextOnly: Bool = false,
        markInternal: Bool = true
    ) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text, .color:
            if !plainTextOnly, let rtfData = item.rtfData {
                pb.setData(rtfData, forType: .rtf)
            }
            if let text = item.plainText ?? item.colorHex {
                pb.setString(text, forType: .string)
            }
        case .link:
            if let urlStr = item.urlString {
                pb.setString(urlStr, forType: .string)
                if !plainTextOnly, let url = URL(string: urlStr) {
                    pb.setString(url.absoluteString, forType: .URL)
                }
            }
        case .image:
            if let filename = item.imageFilename {
                let url = storage.blobURL(for: filename)
                if let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                    if let png = try? Data(contentsOf: url) {
                        pb.setData(png, forType: .png)
                    }
                }
            }
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
            if plainTextOnly {
                pb.setString(item.filePaths.joined(separator: "\n"), forType: .string)
            }
        }

        if markInternal {
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("com.clipshelf.internal"))
        }
    }

    /// Copies the item, hides the shelf, reactivates the previous app, plays the paste sound,
    /// and dispatches a synthetic ⌘V if Accessibility permission is granted.
    public func paste(
        _ item: ClipboardItem,
        storage: SQLiteStorage,
        targetApp: NSRunningApplication?,
        plainTextOnly: Bool = false,
        soundEnabled: Bool,
        dismissShelf: () -> Void
    ) {
        copyToPasteboard(item, storage: storage, plainTextOnly: plainTextOnly, markInternal: true)
        SoundEffectPlayer.shared.playPaste(enabled: soundEnabled)
        dismissShelf()

        NSApp.deactivate()
        targetApp?.activate(options: [])

        guard isAccessibilityTrusted(promptIfNeeded: true) else {
            return
        }

        // Allow target app to regain key focus after panel orders out before synthetic ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.postCommandV()
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
