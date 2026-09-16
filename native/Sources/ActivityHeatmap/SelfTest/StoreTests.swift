import Foundation

/// Exercises `Store`: history merge (91-day horizon, fresh days win),
/// atomic write, and the "never overwrite on failure" rule from
/// ARCHITECTURE.md's "История – критично" section.
enum StoreTests {
    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "store-test-\(UUID().uuidString)/activity.json")
    }

    static func run() {
        SelfTest.suite("Store") {
            testWriteReadRoundtrip()
            testMergeHistoryFreshWinsOverStale()
            testMergeHistoryDropsBeyondHorizon()
            testMergeHistoryEmptyPrevious()
            testAtomicWriteReplacesContent()
            testFailedRefreshDoesNotTouchExistingFile()
            testMissingFileYieldsEmptyPrevious()
            testRefreshWritesCatalogAlongsideHistory()
            testFailedRefreshDoesNotTouchCatalogEither()
        }
    }

    private static func testWriteReadRoundtrip() {
        let store = Store(url: tempURL())
        let snap = ActivitySnapshot(generated: "2026-01-01T00:00:00Z", days: [
            "2026-01-01": DayStats(t: 100, top: [TopEntry(name: "Claude", seconds: 100)])
        ])
        do {
            try store.write(snap)
            let loaded = store.loadPrevious()
            SelfTest.expectEqual(loaded, snap.days, "write/read roundtrip")
        } catch {
            SelfTest.expect(false, "write threw: \(error)")
        }
    }

    private static func testMergeHistoryFreshWinsOverStale() {
        let store = Store(url: tempURL())
        let now = Date()
        let cal = Calendar.current
        let recentDay = isoDay(cal.date(byAdding: .day, value: -5, to: now)!, cal)

        try? store.write(ActivitySnapshot(generated: "x", days: [
            recentDay: DayStats(t: 111, top: [])
        ]))

        let fresh = [recentDay: DayStats(t: 999, top: [TopEntry(name: "New", seconds: 999)])]
        let merged = store.mergeHistory(fresh: fresh, now: now, calendar: cal)
        SelfTest.expectEqual(merged[recentDay]?.t, 999, "fresh day must win over stale copy of the same day")
    }

    private static func testMergeHistoryDropsBeyondHorizon() {
        let store = Store(url: tempURL())
        let now = Date()
        let cal = Calendar.current
        let tooOld = isoDay(cal.date(byAdding: .day, value: -(Store.historyDays + 10), to: now)!, cal)
        let stillIn = isoDay(cal.date(byAdding: .day, value: -(Store.historyDays - 10), to: now)!, cal)

        try? store.write(ActivitySnapshot(generated: "x", days: [
            tooOld: DayStats(t: 1, top: []),
            stillIn: DayStats(t: 2, top: [])
        ]))

        let merged = store.mergeHistory(fresh: [:], now: now, calendar: cal)
        SelfTest.expect(merged[tooOld] == nil, "day older than the 91-day horizon must be dropped")
        SelfTest.expect(merged[stillIn] != nil, "day within the 91-day horizon must survive")
    }

    private static func testMergeHistoryEmptyPrevious() {
        let store = Store(url: tempURL()) // never written
        let merged = store.mergeHistory(fresh: ["2026-01-01": DayStats(t: 5, top: [])])
        SelfTest.expectEqual(merged.count, 1, "merge with no previous file falls back to empty history")
    }

    private static func testAtomicWriteReplacesContent() {
        let store = Store(url: tempURL())
        try? store.write(ActivitySnapshot(generated: "a", days: ["2026-01-01": DayStats(t: 1, top: [])]))
        try? store.write(ActivitySnapshot(generated: "b", days: ["2026-01-02": DayStats(t: 2, top: [])]))
        let loaded = store.loadPrevious()
        SelfTest.expect(loaded["2026-01-01"] == nil, "second atomic write must fully replace, not merge with, the first")
        SelfTest.expect(loaded["2026-01-02"]?.t == 2, "second write's content must be what's on disk")
    }

    private static func testFailedRefreshDoesNotTouchExistingFile() {
        let url = tempURL()
        let store = Store(url: url)
        let original = ActivitySnapshot(generated: "original", days: ["2026-01-01": DayStats(t: 42, top: [])])
        try? store.write(original)

        do {
            _ = try store.refresh(settings: Settings(), dbPath: "/nonexistent/path/knowledgeC.db")
            SelfTest.expect(false, "refresh against a nonexistent DB path must throw")
        } catch {
            // expected
        }

        let after = store.loadPrevious()
        SelfTest.expectEqual(after, original.days, "activity.json must be untouched after a failed refresh")
    }

    private static func testMissingFileYieldsEmptyPrevious() {
        let store = Store(url: tempURL())
        SelfTest.expect(store.loadPrevious().isEmpty, "loadPrevious on a missing file must return an empty map, not throw/crash")
    }

    /// `Store.refresh` writes both `activity.json` and `catalog.json` off
    /// the same db read – confirms the second write actually happens (not
    /// just that `Aggregator.collectCatalog` is correct in isolation,
    /// which `CatalogTests` already covers) by driving a real synthetic
    /// db through the full `refresh()` path.
    private static func testRefreshWritesCatalogAlongsideHistory() {
        let scenario = Fixtures.build()
        guard let dbPath = try? SyntheticKnowledgeDB.build(rows: scenario.events.map { $0.toSyntheticRow() }) else {
            SelfTest.expect(false, "failed to build synthetic DB")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store = Store(url: tempURL(), catalogURL: catalogTempURL())
        do {
            _ = try store.refresh(settings: scenario.settings, dbPath: dbPath, calendar: scenario.calendar)
        } catch {
            SelfTest.expect(false, "refresh threw against synthetic DB: \(error)")
            return
        }

        let catalog = store.catalog.loadPrevious()
        SelfTest.expect(!catalog.isEmpty, "refresh() must also populate catalog.json")
        SelfTest.expectEqual(catalog["com.testApp.Editor"]?.kind, .app, "catalog entry written by refresh() has the right kind")
        // Deny-listed in scenario.settings, but the catalog is unfiltered –
        // must still show up so it stays toggleable in the settings window.
        SelfTest.expect(catalog["com.apple.finder"] != nil, "refresh() writes deny-listed ids to the catalog too")
    }

    private static func testFailedRefreshDoesNotTouchCatalogEither() {
        let catalogURL = catalogTempURL()
        let catalog = Catalog(url: catalogURL)
        let original = ["a.app": CatalogEntry(id: "a.app", kind: .app, name: "A", seconds: 1, lastSeen: "2026-01-01")]
        try? catalog.write(original)

        let store = Store(url: tempURL(), catalogURL: catalogURL)
        do {
            _ = try store.refresh(settings: Settings(), dbPath: "/nonexistent/path/knowledgeC.db")
            SelfTest.expect(false, "refresh against a nonexistent DB path must throw")
        } catch {
            // expected
        }

        SelfTest.expectEqual(catalog.loadPrevious(), original, "catalog.json must be untouched after a failed refresh, same rule as activity.json")
    }

    private static func catalogTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "catalog-test-\(UUID().uuidString)/catalog.json")
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
