import ClipShelfCore
import Foundation
import XCTest

final class ClipShelfCoreTests: XCTestCase {
    private var tempDir: URL!
    private var storage: SQLiteStorage!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipShelfTests-\(UUID().uuidString)", isDirectory: true)
        storage = try SQLiteStorage(baseDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        storage = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testUpsertDeduplicatesAndBumpsTimestamp() {
        let earlier = Date(timeIntervalSinceNow: -300)
        let first = ClipboardItem(
            kind: .text,
            plainText: "brew upgrade waharnss",
            sourceAppBundleID: "com.apple.Terminal",
            sourceAppName: "Terminal",
            createdAt: earlier,
            contentHash: "hash-1"
        )
        let inserted = storage.upsertItem(first)

        let later = Date()
        let duplicate = ClipboardItem(
            kind: .text,
            plainText: "brew upgrade waharnss",
            sourceAppBundleID: "com.apple.Terminal",
            sourceAppName: "Terminal",
            createdAt: later,
            contentHash: "hash-1"
        )
        let bumped = storage.upsertItem(duplicate)

        XCTAssertEqual(inserted.id, bumped.id)
        let all = storage.fetchItems()
        XCTAssertEqual(all.count, 1)
        XCTAssertGreaterThan(all[0].createdAt.timeIntervalSince1970, earlier.timeIntervalSince1970)
    }

    func testPinboardAssignmentSurvivesClearUnpinned() {
        let board = Pinboard(name: "Work", colorHex: "#0A84FF")
        storage.savePinboard(board)

        let pinnedItem = storage.upsertItem(ClipboardItem(kind: .text, plainText: "Keep me", contentHash: "h-keep"))
        let unpinnedItem = storage.upsertItem(ClipboardItem(kind: .text, plainText: "Clear me", contentHash: "h-clear"))
        storage.assignItem(pinnedItem.id, toPinboard: board.id)

        storage.clearUnpinnedHistory()

        let remaining = storage.fetchItems()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, pinnedItem.id)
        XCTAssertEqual(remaining[0].pinboardIDs, [board.id])
        XCTAssertNotEqual(remaining[0].id, unpinnedItem.id)
    }

    func testClipboardRulesFiltersConfidentialTransientAndIgnoredApps() {
        let settings = AppSettings()

        // Default ignored apps: Passwords & Keychain Access
        XCTAssertTrue(ClipboardRules.shouldIgnore(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Passwords", settings: settings))
        XCTAssertTrue(ClipboardRules.shouldIgnore(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.apple.keychainaccess", settings: settings))

        // Confidential & transient markers
        XCTAssertTrue(ClipboardRules.shouldIgnore(pasteboardTypes: ["org.nspasteboard.ConcealedType"], sourceBundleID: "com.google.Chrome", settings: settings))
        XCTAssertTrue(ClipboardRules.shouldIgnore(pasteboardTypes: ["org.nspasteboard.TransientType"], sourceBundleID: "com.google.Chrome", settings: settings))

        // Normal copy from Chrome should pass
        XCTAssertFalse(ClipboardRules.shouldIgnore(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.google.Chrome", settings: settings))

        // Paused blocks everything
        var paused = settings
        paused.isPaused = true
        XCTAssertTrue(ClipboardRules.shouldIgnore(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.google.Chrome", settings: paused))
    }

    func testHexColorAndURLDetection() {
        XCTAssertEqual(ClipboardRules.normalizedHexColor(from: "#0af"), "#00AAFF")
        XCTAssertEqual(ClipboardRules.normalizedHexColor(from: " #30d158 "), "#30D158")
        XCTAssertNil(ClipboardRules.normalizedHexColor(from: "not a color"))

        XCTAssertEqual(ClipboardRules.normalizedWebURL(from: "https://github.com/morluto/rea")?.host, "github.com")
        XCTAssertNil(ClipboardRules.normalizedWebURL(from: "hello world https://example.com"))
    }
}
