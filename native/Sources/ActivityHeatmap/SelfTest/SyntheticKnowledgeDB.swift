import Foundation
import SQLite3

/// Builds a synthetic `knowledgeC.db`-shaped SQLite file (ZOBJECT +
/// ZSTRUCTUREDMETADATA, the two tables the aggregator actually reads) so
/// tests never depend on the real database – which this machine cannot
/// read without Full Disk Access (history/STAGE1.md risk C, confirmed
/// `SQLITE_AUTH`).
enum SyntheticKnowledgeDB {
    struct Row {
        let stream: String            // "/app/usage" | "/app/webUsage" | "/device/isLocked"
        let value: String?            // ZVALUESTRING (bundle id); nil for isLocked rows
        let valueInteger: Int?        // ZVALUEINTEGER; used for isLocked (1 = locked)
        let domain: String?           // joined webdomain, webUsage only
        let start: Double             // Core Data timestamp
        let end: Double                // Core Data timestamp
        /// Simulates a record synced from another device (iPhone, iPad).
        /// knowledgeC merges those into the same tables, and counting them as
        /// local produced a real bug – see `Knowledge.localOnly`.
        var remoteDevice: Bool = false
    }

    /// Local calendar timestamp -> Core Data timestamp (seconds since
    /// 2001-01-01 UTC), matching `Knowledge.coreDataEpoch`.
    static func cd(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0, calendar: Calendar = .current) -> Double {
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: comps) else { fatalError("bad date components") }
        return date.timeIntervalSince1970 - Knowledge.coreDataEpoch
    }

    /// Writes `rows` into a fresh SQLite file at a temp path and returns
    /// that path. Caller is responsible for deleting it.
    static func build(rows: [Row]) throws -> String {
        let path = NSTemporaryDirectory() + "synthetic-knowledgec-\(UUID().uuidString).db"
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "SyntheticKnowledgeDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var errmsg: UnsafeMutablePointer<Int8>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(errmsg)
                throw NSError(domain: "SyntheticKnowledgeDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(msg) – sql: \(sql)"])
            }
        }

        try exec("""
        CREATE TABLE ZSTRUCTUREDMETADATA (
            Z_PK INTEGER PRIMARY KEY,
            Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN TEXT
        );
        """)
        try exec("""
        CREATE TABLE ZOBJECT (
            Z_PK INTEGER PRIMARY KEY,
            ZSTREAMNAME TEXT,
            ZVALUESTRING TEXT,
            ZVALUEINTEGER INTEGER,
            ZSTARTDATE REAL,
            ZENDDATE REAL,
            ZSTRUCTUREDMETADATA INTEGER,
            ZSOURCE INTEGER
        );
        CREATE TABLE ZSOURCE (
            Z_PK INTEGER PRIMARY KEY,
            ZDEVICEID TEXT
        );
        -- Row 1 is this machine (no device id); row 2 stands in for a synced
        -- peer such as an iPhone, so tests can cover the device filter.
        INSERT INTO ZSOURCE (Z_PK, ZDEVICEID) VALUES (1, NULL);
        INSERT INTO ZSOURCE (Z_PK, ZDEVICEID) VALUES (2, 'REMOTE-DEVICE-UUID');
        """)

        var metaPK = 1
        for (i, row) in rows.enumerated() {
            var metaRef = "NULL"
            if let domain = row.domain {
                let escaped = domain.replacingOccurrences(of: "'", with: "''")
                try exec("INSERT INTO ZSTRUCTUREDMETADATA (Z_PK, Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN) VALUES (\(metaPK), '\(escaped)');")
                metaRef = "\(metaPK)"
                metaPK += 1
            }
            let valueSQL = row.value.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
            let intSQL = row.valueInteger.map { "\($0)" } ?? "NULL"
            try exec("""
            INSERT INTO ZOBJECT (Z_PK, ZSTREAMNAME, ZVALUESTRING, ZVALUEINTEGER, ZSTARTDATE, ZENDDATE, ZSTRUCTUREDMETADATA, ZSOURCE)
            VALUES (\(i + 1), '\(row.stream)', \(valueSQL), \(intSQL), \(row.start), \(row.end), \(metaRef), \(row.remoteDevice ? 2 : 1));
            """)
        }
        return path
    }
}
