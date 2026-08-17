import Foundation
import SQLite3

private let SQLITE_TRANSIENT_JDC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CollectionStore {
    static let shared = CollectionStore()

    private var db: OpaquePointer?

    private var databaseURL: URL {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("javdb_collect.sqlite3")
    }

    private init() {
        _ = openDatabase()
        createTable()
    }

    deinit { closeDatabase() }

    @discardableResult
    private func openDatabase() -> Bool {
        closeDatabase()
        var handle: OpaquePointer?
        let result = sqlite3_open(databaseURL.path, &handle)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            db = nil
            print("[JavDBCollect] sqlite open failed: \(result)")
            return false
        }
        db = handle
        return true
    }

    private func closeDatabase() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func createTable() {
        guard db != nil else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS collections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            javdb_id TEXT NOT NULL UNIQUE,
            code TEXT NOT NULL,
            title TEXT NOT NULL,
            magnet TEXT NOT NULL,
            status INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_collections_status ON collections(status);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { print("[JavDBCollect] create table failed: \(errorMessage)") }
    }

    @discardableResult
    func add(movie: MoviePayload, magnet: String) -> Bool {
        let sql = "INSERT OR IGNORE INTO collections (javdb_id, code, title, magnet, status, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        bind(movie.javdbId, to: statement, at: 1)
        bind(movie.code, to: statement, at: 2)
        bind(movie.title, to: statement, at: 3)
        bind(magnet, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, now)
        sqlite3_bind_double(statement, 6, now)

        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    func contains(javdbID: String) -> Bool {
        let sql = "SELECT 1 FROM collections WHERE javdb_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(javdbID, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func collectedIDs(for ids: [String]) -> [String] {
        let uniqueIDs = Array(Set(ids)).filter { !$0.isEmpty }
        guard !uniqueIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
        let sql = "SELECT javdb_id FROM collections WHERE javdb_id IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, id) in uniqueIDs.enumerated() { bind(id, to: statement, at: Int32(index + 1)) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(from: statement, at: 0)) }
        return result
    }

    func fetch(status: Int) -> [CollectRecord] {
        let sql = "SELECT id, javdb_id, code, title, magnet, status, created_at, updated_at FROM collections WHERE status = ? ORDER BY created_at DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(status))
        var records: [CollectRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(CollectRecord(
                id: sqlite3_column_int64(statement, 0),
                javdbID: text(from: statement, at: 1),
                code: text(from: statement, at: 2),
                title: text(from: statement, at: 3),
                magnet: text(from: statement, at: 4),
                status: Int(sqlite3_column_int(statement, 5)),
                createdAt: sqlite3_column_double(statement, 6),
                updatedAt: sqlite3_column_double(statement, 7)
            ))
        }
        return records
    }

    func currentMagnets() -> [String] { fetch(status: 0).map(\.magnet) }

    func moveCurrentToHistory() {
        let now = Date().timeIntervalSince1970
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE collections SET status = 1, updated_at = ? WHERE status = 0;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now)
        sqlite3_step(statement)
    }

    func delete(id: Int64, status: Int) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM collections WHERE id = ? AND status = ?;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_int(statement, 2, Int32(status))
        sqlite3_step(statement)
    }

    func makeDatabaseExport() -> URL? {
        guard let db else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("JavDBCollect-\(formatter.string(from: Date())).sqlite3")
        try? FileManager.default.removeItem(at: exportURL)

        var exportDB: OpaquePointer?
        guard sqlite3_open(exportURL.path, &exportDB) == SQLITE_OK, let exportDB else {
            if let exportDB { sqlite3_close(exportDB) }
            return nil
        }
        defer { sqlite3_close(exportDB) }

        guard let backup = sqlite3_backup_init(exportDB, "main", db, "main") else { return nil }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            try? FileManager.default.removeItem(at: exportURL)
            return nil
        }
        return exportURL
    }

    func importDatabase(from sourceURL: URL) -> Bool {
        guard validateDatabase(at: sourceURL) else { return false }

        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent("JavDBCollect-import-\(UUID().uuidString).sqlite3")
        let backupURL = fileManager.temporaryDirectory.appendingPathComponent("JavDBCollect-before-import-\(UUID().uuidString).sqlite3")
        try? fileManager.removeItem(at: stagingURL)
        try? fileManager.removeItem(at: backupURL)

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
        } catch {
            return false
        }

        closeDatabase()

        do {
            if fileManager.fileExists(atPath: databaseURL.path) { try fileManager.copyItem(at: databaseURL, to: backupURL) }
            if fileManager.fileExists(atPath: databaseURL.path) { try fileManager.removeItem(at: databaseURL) }
            try fileManager.moveItem(at: stagingURL, to: databaseURL)
            guard openDatabase() else { throw NSError(domain: "JavDBCollect.Database", code: 1) }
            createTable()
            guard validateDatabase(at: databaseURL) else { throw NSError(domain: "JavDBCollect.Database", code: 2) }
            try? fileManager.removeItem(at: backupURL)
            return true
        } catch {
            closeDatabase()
            try? fileManager.removeItem(at: databaseURL)
            if fileManager.fileExists(atPath: backupURL.path) { try? fileManager.moveItem(at: backupURL, to: databaseURL) }
            _ = openDatabase()
            createTable()
            try? fileManager.removeItem(at: stagingURL)
            return false
        }
    }

    private func validateDatabase(at url: URL) -> Bool {
        var checkDB: OpaquePointer?
        guard sqlite3_open_v2(url.path, &checkDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let checkDB else {
            if let checkDB { sqlite3_close(checkDB) }
            return false
        }
        defer { sqlite3_close(checkDB) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(checkDB, "PRAGMA table_info(collections);", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) { columns.insert(String(cString: value)) }
        }
        let required: Set<String> = ["id", "javdb_id", "code", "title", "magnet", "status", "created_at", "updated_at"]
        return required.isSubset(of: columns)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        value.withCString { pointer in sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT_JDC) }
    }

    private func text(from statement: OpaquePointer?, at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error" }
}
