import Foundation

/// What kind of identifier a `CatalogEntry` names – mirrors `FilterKind`
/// (Config/SettingsStore.swift) but lives in the data layer and is decided
/// from the *stream* a row came from (`/app/usage` vs `/app/webUsage`),
/// never guessed from the shape of the string. See ARCHITECTURE.md "Каталог
/// идентификаторов".
enum CatalogKind: String, Codable, Equatable {
    case app
    case site
}

/// One raw identifier ever seen in `knowledgeC.db`, independent of the
/// current allow/deny filter – this is the thing `activity.json` cannot
/// give back once the display name has been substituted in. Format per
/// ARCHITECTURE.md "Каталог идентификаторов".
struct CatalogEntry: Codable, Equatable {
    let id: String          // bundle id for .app, domain for .site
    let kind: CatalogKind
    let name: String        // display name at the time of writing
    let seconds: Int        // total time in the most recent observation window, for sorting
    let lastSeen: String    // "YYYY-MM-DD", local calendar
}

/// Owns `catalog.json`: the set of raw identifiers (bundle ids / domains)
/// ever observed, keyed by id. Same accumulation contract as `Store`
/// (Data/Store.swift) applied to identifiers instead of days: entries seen
/// in the latest scan replace the old entry for that id wholesale; entries
/// not seen this time (because their days have aged out of the live
/// knowledgeC.db) survive until `lastSeen` falls outside the 91-day
/// horizon. Same atomic-write, same "never overwrite on a failed read"
/// rule – this is the only surviving record of ids macOS has already
/// pruned from the db, exactly like `activity.json` is for day totals.
final class Catalog {
    static let historyDays = Store.historyDays

    /// `~/Library/Application Support/ActivityHeatmap/catalog.json`
    static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ActivityHeatmap/catalog.json")
    }

    let url: URL

    init(url: URL = Catalog.defaultURL) {
        self.url = url
    }

    static func horizon(now: Date = Date(), calendar: Calendar = .current) -> String {
        Store.horizon(now: now, calendar: calendar)
    }

    /// Empty map if the file is missing or unreadable – same fallback as
    /// `Store.loadPrevious`.
    /// Same rule as `Store.loadPrevious`: a missing catalog is a first run,
    /// an unreadable one is preserved and logged instead of being silently
    /// replaced. The catalog outlives knowledgeC's own retention too.
    func loadPrevious() -> [String: CatalogEntry] {
        let result = HistoryFile.load([String: CatalogEntry].self, from: url)
        return HistoryFile.recover(result, at: url, empty: [:])
    }

    /// Ids still present in `fresh` always win (the latest scan of the
    /// currently-live db is the most accurate data for them); ids not in
    /// `fresh` survive from the previous catalog until their `lastSeen`
    /// ages out of the 91-day horizon.
    func mergeCatalog(fresh: [String: CatalogEntry], now: Date = Date(), calendar: Calendar = .current) -> [String: CatalogEntry] {
        let horizon = Catalog.horizon(now: now, calendar: calendar)
        let previous = loadPrevious()
        var kept = previous.filter { $0.value.lastSeen >= horizon }
        for (id, entry) in fresh {
            kept[id] = entry
        }
        return kept
    }

    enum CatalogError: Error {
        case writeFailed(Error)
    }

    /// Atomic write: temp file next to the target, then
    /// `FileManager.replaceItem` – identical pattern to `Store.write`.
    /// Callers must only call this after a *successful* db read; on any
    /// read/aggregation error the file must be left untouched.
    func write(_ entries: [String: CatalogEntry]) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(entries)
        let tmpURL = dir.appendingPathComponent(url.lastPathComponent + ".tmp-\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItem(at: url, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw CatalogError.writeFailed(error)
            }
        } else {
            do {
                try fm.moveItem(at: tmpURL, to: url)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw CatalogError.writeFailed(error)
            }
        }
    }
}
