import AppKit
import Foundation

@MainActor
public final class SoundEffectPlayer {
    public static let shared = SoundEffectPlayer()

    private var cachedCopySound: NSSound?
    private var cachedPasteSound: NSSound?

    private init() {}

    public func reload() {
        cachedCopySound = loadSound(named: "Copy")
        cachedPasteSound = loadSound(named: "Paste")
    }

    public func playCopy(enabled: Bool) {
        guard enabled else { return }
        if cachedCopySound == nil {
            cachedCopySound = loadSound(named: "Copy")
        }
        guard let sound = cachedCopySound?.copy() as? NSSound ?? cachedCopySound else { return }
        sound.volume = 0.75
        sound.play()
    }

    public func playPaste(enabled: Bool) {
        guard enabled else { return }
        if cachedPasteSound == nil {
            cachedPasteSound = loadSound(named: "Paste")
        }
        guard let sound = cachedPasteSound?.copy() as? NSSound ?? cachedPasteSound else { return }
        sound.volume = 0.75
        sound.play()
    }

    /// Search order:
    /// 1. User override: ~/Library/Application Support/ClipShelf/Sounds/<Name>.{aiff,wav}
    /// 2. Local gitignored override bundled in ClipShelf.app/Contents/Resources/LocalSounds/
    /// 3. Built-in synthesized default in Bundle.module (Resources/Sounds/<Name>.aiff)
    private func loadSound(named name: String) -> NSSound? {
        let fm = FileManager.default
        let extensions = ["aiff", "wav", "caf"]

        // 1. User Application Support override
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let userSounds = appSupport.appendingPathComponent("ClipShelf/Sounds", isDirectory: true)
            for ext in extensions {
                let candidate = userSounds.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: candidate.path), let sound = NSSound(contentsOf: candidate, byReference: true) {
                    return sound
                }
            }
        }

        // 2. LocalSounds override bundled in .app
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("LocalSounds", isDirectory: true) {
            for ext in extensions {
                let candidate = resURL.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: candidate.path), let sound = NSSound(contentsOf: candidate, byReference: true) {
                    return sound
                }
            }
        }

        // 3. Built-in synthesized default in SwiftPM resource bundle
        if let url = Bundle.module.url(forResource: name, withExtension: "aiff", subdirectory: "Sounds")
            ?? Bundle.module.url(forResource: name, withExtension: "aiff") {
            return NSSound(contentsOf: url, byReference: true)
        }

        return nil
    }
}
