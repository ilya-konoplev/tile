import Foundation

/// Regression tests for the two bugs a testing pass turned up.
enum HistoryFileTests {
    static func run() {
        corruptionNeverSilentlyDropsHistory()
        domainsStayWithTheirOwnBrowser()
    }

    // MARK: - A corrupted file must not erase history

    /// The original loader returned an empty map both when the file was
    /// missing and when it failed to decode. The merge then kept nothing and
    /// the next successful refresh wrote a snapshot holding only the few days
    /// still visible in the live database – months of accumulated history
    /// gone, with no error and no log line.
    private static func corruptionNeverSilentlyDropsHistory() {
        SelfTest.suite("HistoryFile/corruption") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("historyfile-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let url = dir.appendingPathComponent("activity.json")
            let catalogURL = dir.appendingPathComponent("catalog.json")

            // Old enough to exist only in this file (macOS keeps a few days),
            // young enough to sit inside the 91-day horizon – otherwise it is
            // legitimately evicted and proves nothing. Anchored to "now" so the
            // test does not rot as the calendar moves.
            let cal = Calendar.current
            let fmt = DateFormatter()
            fmt.calendar = cal
            fmt.timeZone = cal.timeZone
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            let ancient = fmt.string(from: cal.date(byAdding: .day, value: -60, to: Date())!)
            let today = fmt.string(from: Date())
            let fresh = [today: DayStats(t: 3600, top: [])]

            func store() -> Store { Store(url: url, catalogURL: catalogURL) }

            // Control: a valid file keeps the old day through a merge.
            try? store().write(ActivitySnapshot(generated: "x", days: [ancient: DayStats(t: 7200, top: [])]))
            SelfTest.expect(store().mergeHistory(fresh: fresh).keys.contains(ancient),
                            "valid file: the old day survives the merge")

            // Missing file is a first run – empty is correct, nothing to save.
            try? FileManager.default.removeItem(at: url)
            SelfTest.expectEqual(store().mergeHistory(fresh: fresh).count, 1,
                                 "missing file: starts empty")

            // Corrupt and empty files must preserve their bytes rather than
            // being silently treated as "no history".
            for (label, bytes) in [("malformed", Data("{ not json".utf8)), ("empty", Data())] {
                try? store().write(ActivitySnapshot(generated: "x", days: [ancient: DayStats(t: 7200, top: [])]))
                try? bytes.write(to: url)

                _ = store().mergeHistory(fresh: fresh)

                let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                    .filter { $0.contains("activity.json.corrupt-") } ?? []
                SelfTest.expect(!quarantined.isEmpty,
                                "\(label) file: bytes are preserved in quarantine, not overwritten")

                // And the damaged bytes are still readable on disk.
                if let name = quarantined.first,
                   let saved = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                    SelfTest.expectEqual(saved, bytes, "\(label) file: quarantined copy is byte-identical")
                }
                for name in quarantined {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                }
            }
        }
    }

    // MARK: - A domain belongs to the browser it was opened in

    /// Domain time used to be clipped against the union of *every* browser's
    /// foreground time, so a page open in one browser could collect time while
    /// a different browser was the active app.
    private static func domainsStayWithTheirOwnBrowser() {
        SelfTest.suite("HistoryFile/browser attribution") {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
                .addingTimeInterval(9 * 3600)
            func at(_ offset: Double) -> Double {
                base.addingTimeInterval(offset).timeIntervalSince1970 - Knowledge.coreDataEpoch
            }

            var settings = Settings()
            settings.minSeconds = 0

            // Chrome is frontmost for the whole hour. A Safari tab keeps
            // ticking in the background the entire time. Safari is never
            // frontmost, so its domain must earn nothing.
            let usage: [Knowledge.UsageRow] = [
                .init(stream: "/app/usage", value: "com.google.Chrome", domain: nil,
                      start: at(0), end: at(3600)),
                .init(stream: "/app/webUsage", value: "com.google.Chrome", domain: "github.com",
                      start: at(0), end: at(3600)),
                .init(stream: "/app/webUsage", value: "com.apple.Safari", domain: "youtube.com",
                      start: at(0), end: at(3600)),
            ]

            let days = Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal)
            guard let stats = days.values.first else {
                SelfTest.expect(false, "expected one aggregated day")
                return
            }
            let byName = Dictionary(uniqueKeysWithValues: stats.top.map { ($0.name, $0.seconds) })

            SelfTest.expectEqual(byName["github.com"], 3600,
                                 "a domain earns time while its own browser is frontmost")
            SelfTest.expect(byName["youtube.com"] == nil,
                            "a domain in a browser that was never frontmost earns nothing")
        }
    }
}
