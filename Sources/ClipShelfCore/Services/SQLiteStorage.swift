import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStorage: @unchecked Sendable {
    public let baseDirectory: URL
    public let blobsDirectory: URL
    private let dbURL: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.clipshelf.sqlite", qos: .userInitiated)

    public init(baseDirectory: URL? = nil) throws {
        let dir: URL
        if let baseDirectory {
            dir = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("ClipShelf", isDirectory: true)
        }
        self.baseDirectory = dir
        self.blobsDirectory = dir.appendingPathComponent("blobs", isDirectory: true)
        self.dbURL = dir.appendingPathComponent("history.sqlite")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        try openDatabase()
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() throws {
        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(handle)
            throw NSError(domain: "ClipShelf.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    private func migrate() throws {
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            plain_text TEXT,
            rtf_data BLOB,
            url_string TEXT,
            image_filename TEXT,
            image_width INTEGER,
            image_height INTEGER,
            file_paths_json TEXT NOT NULL,
            color_hex TEXT,
            source_app_bundle_id TEXT,
            source_app_name TEXT,
            header_color_hex TEXT NOT NULL,
            created_at REAL NOT NULL,
            content_hash TEXT NOT NULL UNIQUE,
            link_title TEXT,
            link_image_filename TEXT,
            custom_title TEXT
        );
        """)

        exec("""
        CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at DESC);
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS pinboards (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            color_hex TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            created_at REAL NOT NULL
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS item_pinboards (
            item_id TEXT NOT NULL,
            pinboard_id TEXT NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY (item_id, pinboard_id),
            FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE,
            FOREIGN KEY (pinboard_id) REFERENCES pinboards(id) ON DELETE CASCADE
        );
        """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    // MARK: - Blob Helpers

    public func saveBlob(_ data: Data, fileExtension: String) throws -> String {
        let filename = "\(UUID().uuidString).\(fileExtension)"
        let url = blobsDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return filename
    }

    public func blobURL(for filename: String) -> URL {
        blobsDirectory.appendingPathComponent(filename)
    }

    public func removeBlob(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: blobsDirectory.appendingPathComponent(filename))
    }

    // MARK: - Items

    /// Inserts a new item or bumps an existing duplicate (matching `contentHash`) to the top.
    /// Returns the persisted item (preserving existing `id` and `pinboardIDs` if deduplicated).
    @discardableResult
    public func upsertItem(_ item: ClipboardItem) -> ClipboardItem {
        queue.sync {
            if let existing = findItemByHashLocked(item.contentHash) {
                var updated = existing
                updated.createdAt = item.createdAt
                updated.sourceAppBundleID = item.sourceAppBundleID ?? existing.sourceAppBundleID
                updated.sourceAppName = item.sourceAppName ?? existing.sourceAppName
                updated.headerColorHex = item.headerColorHex
                updateTimestampAndSourceLocked(updated)
                return updated
            }

            insertItemLocked(item)
            return item
        }
    }

    public func fetchItems(limit: Int = 500) -> [ClipboardItem] {
        queue.sync {
            guard let db else { return [] }
            let pinMap = fetchItemPinboardsMapLocked()
            let sql = """
            SELECT id, kind, plain_text, rtf_data, url_string, image_filename, image_width, image_height,
                   file_paths_json, color_hex, source_app_bundle_id, source_app_name, header_color_hex,
                   created_at, content_hash, link_title, link_image_filename, custom_title
            FROM items
            ORDER BY created_at DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var results: [ClipboardItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = decodeItemRow(stmt, pinMap: pinMap) {
                    results.append(item)
                }
            }
            return results
        }
    }

    public func fetchLatestHeaderColor(forBundleID bundleID: String) -> String? {
        queue.sync {
            guard let db else { return nil }
            let sql = "SELECT header_color_hex FROM items WHERE source_app_bundle_id = ? AND kind != 'color' ORDER BY created_at DESC LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, bundleID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return columnOptionalText(stmt, 0)
        }
    }

    public func updateLinkPreview(itemID: UUID, title: String?, imageFilename: String?) {
        queue.sync {
            guard let db else { return }
            let sql = "UPDATE items SET link_title = ?, link_image_filename = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindOptionalText(stmt, 1, title)
            bindOptionalText(stmt, 2, imageFilename)
            sqlite3_bind_text(stmt, 3, itemID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func updateCustomTitle(itemID: UUID, title: String?) {
        queue.sync {
            guard let db else { return }
            let sql = "UPDATE items SET custom_title = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindOptionalText(stmt, 1, title)
            sqlite3_bind_text(stmt, 2, itemID.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    public func deleteItem(_ item: ClipboardItem) {
        queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM items WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            removeBlob(item.imageFilename)
            removeBlob(item.linkImageFilename)
        }
    }

    public func clearUnpinnedHistory() {
        queue.sync {
            guard let db else { return }
            // Keep items that belong to any pinboard
            let sql = """
            SELECT id, image_filename, link_image_filename FROM items
            WHERE id NOT IN (SELECT DISTINCT item_id FROM item_pinboards);
            """
            var stmt: OpaquePointer?
            var blobsToRemove: [String] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let f = columnOptionalText(stmt, 1) { blobsToRemove.append(f) }
                    if let f = columnOptionalText(stmt, 2) { blobsToRemove.append(f) }
                }
            }
            sqlite3_finalize(stmt)

            exec("DELETE FROM items WHERE id NOT IN (SELECT DISTINCT item_id FROM item_pinboards);")
            for b in blobsToRemove {
                removeBlob(b)
            }
        }
    }

    public func pruneExpiredItems(olderThan cutoff: Date) {
        queue.sync {
            guard let db else { return }
            let sql = """
            SELECT image_filename, link_image_filename FROM items
            WHERE created_at < ? AND id NOT IN (SELECT DISTINCT item_id FROM item_pinboards);
            """
            var stmt: OpaquePointer?
            var blobsToRemove: [String] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let f = columnOptionalText(stmt, 0) { blobsToRemove.append(f) }
                    if let f = columnOptionalText(stmt, 1) { blobsToRemove.append(f) }
                }
            }
            sqlite3_finalize(stmt)

            let delSQL = """
            DELETE FROM items
            WHERE created_at < ? AND id NOT IN (SELECT DISTINCT item_id FROM item_pinboards);
            """
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(delStmt, 1, cutoff.timeIntervalSince1970)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            for b in blobsToRemove {
                removeBlob(b)
            }
        }
    }

    // MARK: - Pinboards

    public func fetchPinboards() -> [Pinboard] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, name, color_hex, sort_order, created_at FROM pinboards ORDER BY sort_order ASC, created_at ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var results: [Pinboard] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = columnOptionalText(stmt, 0),
                      let id = UUID(uuidString: idStr),
                      let name = columnOptionalText(stmt, 1),
                      let colorHex = columnOptionalText(stmt, 2) else { continue }
                let sortOrder = Int(sqlite3_column_int(stmt, 3))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                results.append(Pinboard(id: id, name: name, colorHex: colorHex, sortOrder: sortOrder, createdAt: createdAt))
            }
            return results
        }
    }

    public func savePinboard(_ pinboard: Pinboard) {
        queue.sync {
            guard let db else { return }
            let sql = """
            INSERT INTO pinboards (id, name, color_hex, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, color_hex = excluded.color_hex, sort_order = excluded.sort_order;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pinboard.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, pinboard.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, pinboard.colorHex, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(pinboard.sortOrder))
            sqlite3_bind_double(stmt, 5, pinboard.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func deletePinboard(id: UUID) {
        queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM pinboards WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func assignItem(_ itemID: UUID, toPinboard pinboardID: UUID) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT OR IGNORE INTO item_pinboards (item_id, pinboard_id, added_at) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, pinboardID.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func removeItem(_ itemID: UUID, fromPinboard pinboardID: UUID) {
        queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM item_pinboards WHERE item_id = ? AND pinboard_id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, itemID.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, pinboardID.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Private Locked Helpers

    private func findItemByHashLocked(_ hash: String) -> ClipboardItem? {
        guard let db else { return nil }
        let sql = """
        SELECT id, kind, plain_text, rtf_data, url_string, image_filename, image_width, image_height,
               file_paths_json, color_hex, source_app_bundle_id, source_app_name, header_color_hex,
               created_at, content_hash, link_title, link_image_filename, custom_title
        FROM items WHERE content_hash = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let pinMap = fetchItemPinboardsMapLocked()
        return decodeItemRow(stmt, pinMap: pinMap)
    }

    private func insertItemLocked(_ item: ClipboardItem) {
        guard let db else { return }
        let sql = """
        INSERT INTO items (
            id, kind, plain_text, rtf_data, url_string, image_filename, image_width, image_height,
            file_paths_json, color_hex, source_app_bundle_id, source_app_name, header_color_hex,
            created_at, content_hash, link_title, link_image_filename, custom_title
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let pathsJSON = (try? JSONEncoder().encode(item.filePaths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 3, item.plainText)
        bindOptionalBlob(stmt, 4, item.rtfData)
        bindOptionalText(stmt, 5, item.urlString)
        bindOptionalText(stmt, 6, item.imageFilename)
        bindOptionalInt(stmt, 7, item.imageWidth)
        bindOptionalInt(stmt, 8, item.imageHeight)
        sqlite3_bind_text(stmt, 9, pathsJSON, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 10, item.colorHex)
        bindOptionalText(stmt, 11, item.sourceAppBundleID)
        bindOptionalText(stmt, 12, item.sourceAppName)
        sqlite3_bind_text(stmt, 13, item.headerColorHex, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 14, item.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 15, item.contentHash, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 16, item.linkTitle)
        bindOptionalText(stmt, 17, item.linkImageFilename)
        bindOptionalText(stmt, 18, item.customTitle)
        sqlite3_step(stmt)
    }

    private func updateTimestampAndSourceLocked(_ item: ClipboardItem) {
        guard let db else { return }
        let sql = "UPDATE items SET created_at = ?, source_app_bundle_id = ?, source_app_name = ?, header_color_hex = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, item.createdAt.timeIntervalSince1970)
        bindOptionalText(stmt, 2, item.sourceAppBundleID)
        bindOptionalText(stmt, 3, item.sourceAppName)
        sqlite3_bind_text(stmt, 4, item.headerColorHex, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func fetchItemPinboardsMapLocked() -> [UUID: [UUID]] {
        guard let db else { return [:] }
        let sql = "SELECT item_id, pinboard_id FROM item_pinboards;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [UUID: [UUID]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let itemStr = columnOptionalText(stmt, 0),
               let pinStr = columnOptionalText(stmt, 1),
               let itemID = UUID(uuidString: itemStr),
               let pinID = UUID(uuidString: pinStr) {
                map[itemID, default: []].append(pinID)
            }
        }
        return map
    }

    private func decodeItemRow(_ stmt: OpaquePointer?, pinMap: [UUID: [UUID]]) -> ClipboardItem? {
        guard let idStr = columnOptionalText(stmt, 0),
              let id = UUID(uuidString: idStr),
              let kindStr = columnOptionalText(stmt, 1),
              let kind = ClipboardItemKind(rawValue: kindStr),
              let headerColor = columnOptionalText(stmt, 12),
              let hash = columnOptionalText(stmt, 14) else {
            return nil
        }

        let pathsStr = columnOptionalText(stmt, 8) ?? "[]"
        let filePaths = (pathsStr.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []

        return ClipboardItem(
            id: id,
            kind: kind,
            plainText: columnOptionalText(stmt, 2),
            rtfData: columnOptionalBlob(stmt, 3),
            urlString: columnOptionalText(stmt, 4),
            imageFilename: columnOptionalText(stmt, 5),
            imageWidth: columnOptionalInt(stmt, 6),
            imageHeight: columnOptionalInt(stmt, 7),
            filePaths: filePaths,
            colorHex: columnOptionalText(stmt, 9),
            sourceAppBundleID: columnOptionalText(stmt, 10),
            sourceAppName: columnOptionalText(stmt, 11),
            headerColorHex: headerColor,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
            contentHash: hash,
            linkTitle: columnOptionalText(stmt, 15),
            linkImageFilename: columnOptionalText(stmt, 16),
            customTitle: columnOptionalText(stmt, 17),
            pinboardIDs: pinMap[id] ?? []
        )
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data?) {
        if let data, !data.isEmpty {
            _ = data.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cStr)
    }

    private func columnOptionalBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    private func columnOptionalInt(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, index))
    }
}
