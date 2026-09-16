import Foundation
import SQLite3

/// Stage 1 risk probe C: can this app read knowledgeC.db at all?
///
/// This is NOT the production reader (that's Data/Knowledge.swift in
/// stage 2, which per ARCHITECTURE.md must copy the db + -wal/-shm to a temp
/// location before reading). Here we just try to open the live file
/// read-only and COUNT(*) rows in ZOBJECT, to find out – and log –
/// whether TCC/Full Disk Access is currently granted to this exact
/// signed binary.
enum FullDiskAccessProbe {
    static func run() {
        let path = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
            .path

        guard FileManager.default.fileExists(atPath: path) else {
            appLog("RISK-C: knowledgeC.db not found at \(path)")
            return
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }

        guard openResult == SQLITE_OK, let db else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            appLog("RISK-C: sqlite3_open_v2 failed (code=\(openResult)): \(errMsg) – Full Disk Access is NOT granted to this binary.")
            return
        }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM ZOBJECT;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            appLog("RISK-C: prepare failed: \(errMsg) – likely blocked by TCC despite file existing (open succeeded, read denied).")
            return
        }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_int64(statement, 0)
            appLog("RISK-C: SUCCESS – read \(count) rows from ZOBJECT. Full Disk Access IS granted to this binary.")
        } else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            appLog("RISK-C: step failed: \(errMsg)")
        }
    }
}
