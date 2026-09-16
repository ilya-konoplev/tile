import Foundation

/// Exercises the identifier catalog (ARCHITECTURE.md "Каталог идентификаторов"):
/// `Aggregator.collectCatalog` (kind comes from the stream, not the shape
/// of the string; unfiltered by allow/deny) and `Catalog` (91-day
/// accumulation across scans, atomic write, survives a failed read –
/// same contract as `Store`/`activity.json`, applied per-id instead of
/// per-day).
enum CatalogTests {
    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "catalog-test-\(UUID().uuidString)/catalog.json")
    }

    static func run() {
        SelfTest.suite("Aggregator.collectCatalog") {
            let scenario = Fixtures.build()
            let usage = scenario.events.compactMap { $0.toUsageRow(calendar: scenario.calendar) }
            let locked = scenario.events.compactMap { $0.toLockedRow() }

            let catalog = Aggregator.collectCatalog(usage: usage, locked: locked, settings: scenario.settings, calendar: scenario.calendar)

            // Kind comes from the stream: apps from /app/usage, domains
            // from /app/webUsage – including the browser bundle id itself
            // (com.apple.Safari), which /app/usage also logs directly.
            SelfTest.expectEqual(catalog["com.testApp.Editor"]?.kind, .app, "bundle id from /app/usage -> .app")
            SelfTest.expectEqual(catalog["com.apple.Safari"]?.kind, .app, "browser bundle id itself is still an .app entry")
            SelfTest.expectEqual(catalog["github.com"]?.kind, .site, "domain from /app/webUsage -> .site")
            SelfTest.expectEqual(catalog["backgroundtab.example.com"]?.kind, .site, "background-tab domain -> .site")

            // Deny-listed apps are NOT filtered out of the catalog – the
            // whole point is to show what was seen regardless of the
            // current filter, so the settings window can still offer it
            // as a toggle. `collect()`'s day totals correctly exclude it
            // (see AggregatorTests); the catalog must not.
            SelfTest.expect(catalog["com.apple.finder"] != nil, "deny-listed app still recorded in the catalog")
            SelfTest.expectEqual(catalog["com.apple.finder"]?.kind, .app, "deny-listed app kind still correct")

            // Union across both days it appears on, minus the overnight
            // lock's effect on the day-B midnight piece: 10:00-11:00
            // (3600s) + 23:30-24:00 piece (1800s) + 00:00-00:30 piece
            // (1800s) = 7200s total, last seen on day B.
            SelfTest.expectEqual(catalog["com.testApp.Editor"]?.seconds, 7200, "Editor seconds summed across both days it appears on")
            SelfTest.expectEqual(catalog["com.testApp.Editor"]?.lastSeen, scenario.dayB, "Editor last seen on the later day")

            // NightOwl: 02:00-04:00 minus the 02:30-03:30 lock = 3600s,
            // matching the day-B total AggregatorTests derives.
            SelfTest.expectEqual(catalog["com.testApp.NightOwl"]?.seconds, 3600, "NightOwl seconds account for the overnight lock")

            // Background tab: the catalog does NOT cap a domain's time to
            // its browser's foreground window (that's a `collect()`-only
            // refinement for the day breakdown) – it just sums the
            // domain's own raw presence, 09:00-11:00 = 7200s here. This is
            // "суммарное время... для сортировки", not an exact accounting.
            SelfTest.expectEqual(catalog["backgroundtab.example.com"]?.seconds, 7200, "catalog seconds are raw presence, not foreground-capped")

            // Display name resolves through the same Aggregator.displayName
            // (with overrides) collect() itself uses.
            SelfTest.expectEqual(catalog["com.testApp.Editor"]?.name, "Editor", "catalog entry name uses displayName")

            SelfTest.expect(Aggregator.collectCatalog(usage: [], locked: [], settings: scenario.settings).isEmpty, "empty input -> empty catalog, no crash")
        }

        SelfTest.suite("Aggregator.collectCatalog – kind from stream, not string shape") {
            // A bundle id that looks exactly like a domain (three
            // dot-separated segments ending in a TLD-ish word) must still
            // be classified .app because it arrived on /app/usage – this
            // is the specific defect the catalog exists to fix (see
            // ARCHITECTURE.md "Каталог идентификаторов" / history/STAGE4.md "Известное
            // ограничение").
            let row = Knowledge.UsageRow(stream: "/app/usage", value: "widget.example.app", domain: nil, start: 0, end: 60)
            var settings = Settings()
            settings.minSeconds = 0
            let catalog = Aggregator.collectCatalog(usage: [row], locked: [], settings: settings)
            SelfTest.expectEqual(catalog["widget.example.app"]?.kind, .app, "domain-shaped bundle id from /app/usage is still .app")

            // Symmetric case: a domain that looks exactly like a bundle id
            // (starts with a generic reverse-DNS-ish segment) must still
            // be classified .site because it arrived on /app/webUsage.
            let webRow = Knowledge.UsageRow(stream: "/app/webUsage", value: "com.browser.bundle", domain: "com.example.tricky", start: 0, end: 60)
            let webCatalog = Aggregator.collectCatalog(usage: [webRow], locked: [], settings: settings)
            SelfTest.expectEqual(webCatalog["com.example.tricky"]?.kind, .site, "bundle-id-shaped domain from /app/webUsage is still .site")
        }

        SelfTest.suite("Catalog persistence") {
            testWriteReadRoundtrip()
            testMergeFreshWinsOverStale()
            testMergeDropsBeyondHorizon()
            testMergeEmptyPrevious()
            testAtomicWriteReplacesContent()
            testMissingFileYieldsEmptyPrevious()
            testMalformedFileYieldsEmptyPrevious()
        }
    }

    private static func testWriteReadRoundtrip() {
        let catalog = Catalog(url: tempURL())
        let entries = ["org.videolan.vlc": CatalogEntry(id: "org.videolan.vlc", kind: .app, name: "VLC", seconds: 120, lastSeen: "2026-07-01")]
        do {
            try catalog.write(entries)
            SelfTest.expectEqual(catalog.loadPrevious(), entries, "write/read roundtrip")
        } catch {
            SelfTest.expect(false, "write threw: \(error)")
        }
    }

    private static func testMergeFreshWinsOverStale() {
        let catalog = Catalog(url: tempURL())
        let now = Date()
        let cal = Calendar.current
        let recentDay = isoDay(cal.date(byAdding: .day, value: -5, to: now)!, cal)

        try? catalog.write(["a.app": CatalogEntry(id: "a.app", kind: .app, name: "Old", seconds: 10, lastSeen: recentDay)])

        let fresh = ["a.app": CatalogEntry(id: "a.app", kind: .app, name: "New", seconds: 999, lastSeen: recentDay)]
        let merged = catalog.mergeCatalog(fresh: fresh, now: now, calendar: cal)
        SelfTest.expectEqual(merged["a.app"]?.seconds, 999, "fresh entry for an id present in this scan must win over the stale copy")
        SelfTest.expectEqual(merged["a.app"]?.name, "New", "fresh entry's name wins too")
    }

    private static func testMergeDropsBeyondHorizon() {
        let catalog = Catalog(url: tempURL())
        let now = Date()
        let cal = Calendar.current
        let tooOld = isoDay(cal.date(byAdding: .day, value: -(Catalog.historyDays + 10), to: now)!, cal)
        let stillIn = isoDay(cal.date(byAdding: .day, value: -(Catalog.historyDays - 10), to: now)!, cal)

        try? catalog.write([
            "gone.app": CatalogEntry(id: "gone.app", kind: .app, name: "Gone", seconds: 1, lastSeen: tooOld),
            "kept.app": CatalogEntry(id: "kept.app", kind: .app, name: "Kept", seconds: 2, lastSeen: stillIn),
        ])

        // No fresh scan sees either id again (e.g. neither app ran during
        // this observation window) – an id whose `lastSeen` fell outside
        // the 91-day horizon must be dropped even though it isn't in
        // `fresh`, exactly like a too-old day in `activity.json`.
        let merged = catalog.mergeCatalog(fresh: [:], now: now, calendar: cal)
        SelfTest.expect(merged["gone.app"] == nil, "id last seen beyond the 91-day horizon must be dropped")
        SelfTest.expect(merged["kept.app"] != nil, "id last seen within the 91-day horizon must survive")
    }

    private static func testMergeEmptyPrevious() {
        let catalog = Catalog(url: tempURL()) // never written
        let merged = catalog.mergeCatalog(fresh: ["a.app": CatalogEntry(id: "a.app", kind: .app, name: "A", seconds: 5, lastSeen: "2026-01-01")])
        SelfTest.expectEqual(merged.count, 1, "merge with no previous catalog file falls back to empty")
    }

    private static func testAtomicWriteReplacesContent() {
        let catalog = Catalog(url: tempURL())
        try? catalog.write(["a.app": CatalogEntry(id: "a.app", kind: .app, name: "A", seconds: 1, lastSeen: "2026-01-01")])
        try? catalog.write(["b.app": CatalogEntry(id: "b.app", kind: .app, name: "B", seconds: 2, lastSeen: "2026-01-02")])
        let loaded = catalog.loadPrevious()
        SelfTest.expect(loaded["a.app"] == nil, "second atomic write must fully replace, not merge with, the first")
        SelfTest.expect(loaded["b.app"]?.seconds == 2, "second write's content must be what's on disk")
    }

    private static func testMissingFileYieldsEmptyPrevious() {
        let catalog = Catalog(url: tempURL())
        SelfTest.expect(catalog.loadPrevious().isEmpty, "loadPrevious on a missing file must return an empty map, not throw/crash")
    }

    private static func testMalformedFileYieldsEmptyPrevious() {
        let url = tempURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: url)
        let catalog = Catalog(url: url)
        SelfTest.expect(catalog.loadPrevious().isEmpty, "loadPrevious on a malformed file must return an empty map, not throw/crash")
    }

    private static func isoDay(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
