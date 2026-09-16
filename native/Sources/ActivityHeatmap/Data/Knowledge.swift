import Foundation
import SQLite3

/// Reads `knowledgeC.db`. Port of `open_db` + the two SQL queries in
/// `collect()` from the Python prototype's `aggregate.py`.
///
/// The db is usually WAL-locked by the OS (and blocked outright without
/// Full Disk Access – see history/STAGE1.md risk C), so per ARCHITECTURE.md we always
/// copy it, plus its `-wal`/`-shm` siblings, to a temp directory first and
/// read the copy.
enum Knowledge {
    /// Core Data epoch offset: 2001-01-01 00:00:00 UTC, in Unix seconds.
    static let coreDataEpoch: Double = 978_307_200

    struct UsageRow {
        let stream: String        // "/app/usage" or "/app/webUsage"
        let value: String         // bundle id (both streams carry it in ZVALUESTRING)
        let domain: String?       // joined ZSTRUCTUREDMETADATA webdomain, webUsage only
        let start: Double         // Unix seconds
        let end: Double           // Unix seconds
    }

    struct LockedRow {
        let start: Double
        let end: Double
    }

    enum KnowledgeError: Error, CustomStringConvertible {
        case notFound(String)
        case copyFailed(String)
        case sqlite(String)

        var description: String {
            switch self {
            case .notFound(let path): return "knowledgeC.db not found at \(path)"
            case .copyFailed(let reason): return "failed to copy knowledgeC.db: \(reason)"
            case .sqlite(let reason): return reason
            }
        }
    }

    static var defaultDBPath: String {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
            .path
    }

    /// Copies `dbPath` (+ `-wal`/`-shm` if present) into a fresh temp
    /// directory and returns the path to the copy plus the temp directory
    /// (caller must remove it when done).
    static func copyAside(dbPath: String) throws -> (dbPath: String, tmpDir: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else {
            throw KnowledgeError.notFound(dbPath)
        }
        let tmpDir = NSTemporaryDirectory() + "knowledgec-" + UUID().uuidString
        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            let localDB = tmpDir + "/knowledgeC.db"
            try fm.copyItem(atPath: dbPath, toPath: localDB)
            for suffix in ["-wal", "-shm"] {
                let side = dbPath + suffix
                if fm.fileExists(atPath: side) {
                    try fm.copyItem(atPath: side, toPath: localDB + suffix)
                }
            }
            return (localDB, tmpDir)
        } catch {
            try? fm.removeItem(atPath: tmpDir)
            throw KnowledgeError.copyFailed("\(error)")
        }
    }

    /// Opens the copy read-only, runs both queries, closes it, and cleans
    /// up the temp directory – mirrors `collect()`'s `open_db()` /
    /// `finally` block.
    static func loadRows(dbPath: String = defaultDBPath, cutoff: Double) throws -> (usage: [UsageRow], locked: [LockedRow]) {
        let (localPath, tmpDir) = try copyAside(dbPath: dbPath)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(localPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "sqlite3_open_v2 failed"
            sqlite3_close(db)
            throw KnowledgeError.sqlite("sqlite3_open_v2: \(msg)")
        }
        defer { sqlite3_close(db) }

        let usage = try queryUsage(db: db, cutoff: cutoff)
        let locked = try queryLocked(db: db, cutoff: cutoff)
        return (usage, locked)
    }

    /// knowledgeC is shared across the user's devices: an iPhone's records sync
    /// into the Mac's database with the same stream names. Every query below
    /// therefore restricts itself to LOCAL records – `ZSOURCE.ZDEVICEID IS NULL`
    /// marks "this machine", a non-null device id marks a synced peer.
    ///
    /// This is not hypothetical. Measured on real data: `/app/usage` was
    /// entirely local (6376 rows), while every single `/device/isLocked` row
    /// (1084 of them, 167 hours) came from one remote device id. Subtracting
    /// those "locked" windows meant subtracting the phone's screen-lock periods
    /// from the Mac's activity – on 14 July that removed 385 minutes of real
    /// work, turning a 7-hour day into 36 minutes.
    private static let localOnly = "AND (o.ZSOURCE IS NULL OR (SELECT s.ZDEVICEID FROM ZSOURCE s WHERE s.Z_PK = o.ZSOURCE) IS NULL)"

    private static func queryUsage(db: OpaquePointer, cutoff: Double) throws -> [UsageRow] {
        let sql = """
        SELECT o.ZSTREAMNAME, o.ZVALUESTRING,
               m.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN,
               o.ZSTARTDATE, o.ZENDDATE
        FROM ZOBJECT o
        LEFT JOIN ZSTRUCTUREDMETADATA m ON o.ZSTRUCTUREDMETADATA = m.Z_PK
        WHERE o.ZSTREAMNAME IN ('/app/usage', '/app/webUsage')
          AND o.ZSTARTDATE >= ?
          AND o.ZVALUESTRING IS NOT NULL
          AND o.ZENDDATE > o.ZSTARTDATE
          \(localOnly)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw KnowledgeError.sqlite("prepare usage: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        var rows: [UsageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let streamC = sqlite3_column_text(stmt, 0),
                  let valueC = sqlite3_column_text(stmt, 1) else { continue }
            let stream = String(cString: streamC)
            let value = String(cString: valueC)
            let domain: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let start = sqlite3_column_double(stmt, 3)
            let end = sqlite3_column_double(stmt, 4)
            rows.append(UsageRow(stream: stream, value: value, domain: domain, start: start, end: end))
        }
        return rows
    }

    private static func queryLocked(db: OpaquePointer, cutoff: Double) throws -> [LockedRow] {
        let sql = """
        SELECT o.ZSTARTDATE, o.ZENDDATE FROM ZOBJECT o
        WHERE o.ZSTREAMNAME = '/device/isLocked'
          AND o.ZVALUEINTEGER = 1 AND o.ZSTARTDATE >= ? AND o.ZENDDATE > o.ZSTARTDATE
          \(localOnly)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw KnowledgeError.sqlite("prepare locked: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)

        var rows: [LockedRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let start = sqlite3_column_double(stmt, 0)
            let end = sqlite3_column_double(stmt, 1)
            rows.append(LockedRow(start: start, end: end))
        }
        return rows
    }
}
