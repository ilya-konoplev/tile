import Foundation

/// Loading rules for the two files that hold irreplaceable data:
/// `activity.json` (day history) and `catalog.json` (identifier catalog).
/// macOS prunes `knowledgeC.db` after a few days, so anything older than that
/// window exists **only** in these files. Losing them loses it for good.
///
/// The bug this type exists to prevent: both loaders used to treat "the file
/// is there but will not parse" exactly like "there is no file" – both
/// returned an empty map. The merge step then kept nothing, and the next
/// successful refresh atomically wrote a snapshot containing only the handful
/// of days still visible in the live database. Months of accumulated history
/// could vanish with no error and no log line.
///
/// Verified before the fix: a valid file kept an old day through a merge; the
/// same file truncated or emptied silently dropped it.
enum HistoryFile {
    enum LoadResult<T> {
        /// No file yet – a first run. Starting empty is correct here.
        case missing
        case loaded(T)
        /// The file exists but cannot be decoded. Its bytes are preserved
        /// (see `quarantine`), never overwritten in place.
        case corrupt(Error)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> LoadResult<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            // An empty file is corruption, not absence: something wrote zero
            // bytes where a snapshot should be, which is exactly what a
            // half-finished write looks like.
            guard !data.isEmpty else {
                return .corrupt(CocoaError(.fileReadCorruptFile))
            }
            return .loaded(try JSONDecoder().decode(type, from: data))
        } catch {
            return .corrupt(error)
        }
    }

    /// Moves an unreadable file aside instead of letting it be overwritten,
    /// so its bytes survive for manual recovery, and returns the path it was
    /// moved to. The app then starts a fresh file – it recovers rather than
    /// failing forever, but nothing is destroyed on the way.
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            appLog("HistoryFile: could not quarantine \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Shared handling: log loudly, preserve the bytes, continue empty.
    static func recover<T>(_ result: LoadResult<T>, at url: URL, empty: T) -> T {
        switch result {
        case .missing:
            return empty
        case .loaded(let value):
            return value
        case .corrupt(let error):
            let moved = quarantine(url)
            appLog("""
            HistoryFile: \(url.lastPathComponent) is unreadable (\(error)). \
            This file is the only copy of history macOS has already pruned. \
            Its bytes were preserved at \(moved?.lastPathComponent ?? "<quarantine failed>"); \
            starting a fresh file.
            """)
            return empty
        }
    }
}
