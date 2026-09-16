import Foundation

/// Owns `activity.json`: merges freshly-collected days into the rolling
/// 91-day history, writes atomically, and never lets a failed refresh
/// clobber the file. Port of `merge_history` / the write half of `main()`
/// in the Python prototype's `aggregate.py`. The hourly clock that drives
/// this used to live here as a `Timer`; it now lives in `AppDelegate`
/// (`startRefreshLoop`) so a tick refreshes the on-screen widget too, not just
/// the file, and so it can be protected from App Nap — see that method.
final class Store {
    static let historyDays = 91

    /// `~/Library/Application Support/ActivityHeatmap/activity.json`
    static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ActivityHeatmap/activity.json")
    }

    let url: URL
    let catalog: Catalog

    init(url: URL = Store.defaultURL, catalogURL: URL = Catalog.defaultURL) {
        self.url = url
        self.catalog = Catalog(url: catalogURL)
    }

    /// Days at or after this ISO date string are kept from the previous
    /// snapshot (mirrors `merge_history`'s `horizon`).
    static func horizon(now: Date = Date(), calendar: Calendar = .current) -> String {
        let cutoff = calendar.date(byAdding: .day, value: -historyDays, to: now) ?? now
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: cutoff)
    }

    /// Reads whatever is currently on disk. A missing file yields an empty
    /// map (first run); an *unreadable* one is quarantined and logged rather
    /// than silently treated as empty – see `HistoryFile` for why that
    /// distinction is the difference between a fresh start and losing every
    /// day macOS has already pruned.
    func loadPrevious() -> [String: DayStats] {
        let result = HistoryFile.load(ActivitySnapshot.self, from: url)
        return HistoryFile.recover(result, at: url, empty: ActivitySnapshot(generated: "", days: [:])).days
    }

    /// Days still present in `fresh` always win (the DB may have grown
    /// since last run); older days survive from the previous snapshot
    /// until they age out of the 91-day horizon.
    func mergeHistory(fresh: [String: DayStats], now: Date = Date(), calendar: Calendar = .current) -> [String: DayStats] {
        let horizon = Store.horizon(now: now, calendar: calendar)
        let previous = loadPrevious()
        var kept = previous.filter { $0.key >= horizon }
        for (day, stats) in fresh {
            kept[day] = stats
        }
        return kept
    }

    enum StoreError: Error {
        case writeFailed(Error)
    }

    /// Atomic write: temp file next to the target, then
    /// `FileManager.replaceItem`. Per ARCHITECTURE.md, callers must only call
    /// this on a *successful* refresh – on any read/aggregation error the
    /// file must be left untouched, since it is the only surviving copy
    /// of days macOS has already pruned from knowledgeC.db.
    func write(_ snapshot: ActivitySnapshot) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(snapshot)
        let tmpURL = dir.appendingPathComponent(url.lastPathComponent + ".tmp-\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItem(at: url, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw StoreError.writeFailed(error)
            }
        } else {
            do {
                try fm.moveItem(at: tmpURL, to: url)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw StoreError.writeFailed(error)
            }
        }
    }

    /// Runs one collect-merge-write cycle. Returns the snapshot that was
    /// (or would have been) written. On any error, the file on disk is
    /// left untouched and the error is rethrown – caller decides how to
    /// surface it (log, menu bar badge, etc.).
    @discardableResult
    func refresh(
        settings: Settings,
        dbPath: String = Knowledge.defaultDBPath,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ActivitySnapshot {
        let cutoffDate = calendar.date(byAdding: .day, value: -Store.historyDays, to: now) ?? now
        let cutoffCoreData = cutoffDate.timeIntervalSince1970 - Knowledge.coreDataEpoch
        let (usage, locked) = try Knowledge.loadRows(dbPath: dbPath, cutoff: cutoffCoreData)
        let fresh = Aggregator.collect(usage: usage, locked: locked, settings: settings, calendar: calendar)
        let merged = mergeHistory(fresh: fresh, now: now, calendar: calendar)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let snapshot = ActivitySnapshot(generated: iso.string(from: now), days: merged)
        try write(snapshot)

        // Same read, same success gate: the identifier catalog (ARCHITECTURE.md
        // "Каталог идентификаторов") is built from the exact rows that
        // just produced `snapshot`, so a failed db read above never
        // reaches here and never touches catalog.json either.
        let freshCatalog = Aggregator.collectCatalog(usage: usage, locked: locked, settings: settings, calendar: calendar)
        let mergedCatalog = catalog.mergeCatalog(fresh: freshCatalog, now: now, calendar: calendar)
        try catalog.write(mergedCatalog)

        return snapshot
    }

}
