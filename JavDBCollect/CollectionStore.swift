import Foundation
import SQLite3

private let SQLITE_TRANSIENT_JDC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CollectionStore {
    static let shared = CollectionStore()

    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTable()
    }

    deinit { if let db { sqlite3_close(db) } }

    private func openDatabase() {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let databaseURL = baseURL.appendingPathComponent("javdb_collect.sqlite3")
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK { print("[JavDBCollect] sqlite open failed: \(errorMessage)") }
    }

    private func createTable() {
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

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        value.withCString { pointer in sqlite3_bind_text(statement, index, pointer, -1, SQLITE_TRANSIENT_JDC) }
    }

    private func text(from statement: OpaquePointer?, at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error" }
}
