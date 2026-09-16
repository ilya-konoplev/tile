import Foundation

/// Exercises `Aggregator.collect` directly (no DB involved) against the
/// shared `Fixtures.build()` scenario, with hand-derived expected numbers.
/// See `Fixtures.swift` for the full walkthrough of what each event proves.
enum AggregatorTests {
    static func run() {
        SelfTest.suite("Aggregator") {
            let scenario = Fixtures.build()
            let usage = scenario.events.compactMap { $0.toUsageRow(calendar: scenario.calendar) }
            let locked = scenario.events.compactMap { $0.toLockedRow() }

            let days = Aggregator.collect(usage: usage, locked: locked, settings: scenario.settings, calendar: scenario.calendar)

            guard let a = days[scenario.dayA] else {
                SelfTest.expect(false, "day A (\(scenario.dayA)) missing from result – got keys \(days.keys.sorted())")
                return
            }
            guard let b = days[scenario.dayB] else {
                SelfTest.expect(false, "day B (\(scenario.dayB)) missing from result – got keys \(days.keys.sorted())")
                return
            }

            // Day A: Editor union(10:00-11:00, 23:30-24:00) = 3600+1800 = 5400s.
            //        Safari itself hidden (browser); backgroundtab.example.com
            //        capped to the 600s foreground window, not its raw 7200s
            //        span; github.com's 360s sits entirely inside that window.
            //        finder excluded entirely (deny-listed).
            //        total = 3600(editor am)+1800(editor midnight piece)+600(safari fg) = 6000s.
            //
            //        The two domains overlap for github.com's whole 360s, and
            //        that shared time is split between them rather than counted
            //        twice: background 600-360+180 = 420, github 180. Before the
            //        split they summed to 960s against 600s of actual browsing –
            //        the invariant "per-domain time <= browser foreground time"
            //        was broken, which let a pinned tab cancel out real work.
            SelfTest.expectEqual(a.t, 6000, "day A total")
            SelfTest.expectEqual(a.top.map(\.name), ["Editor", "backgroundtab.example.com", "github.com"], "day A ranking")
            SelfTest.expectEqual(a.top.map(\.seconds), [5400, 420, 180], "day A seconds (overlap shared)")
            SelfTest.expect(a.top.dropFirst().map(\.seconds).reduce(0, +) <= 600,
                            "domains never exceed the browser's foreground time")

            // Day B: Editor midnight piece 00:00-00:30 = 1800s (unaffected by
            // the lock, which is 02:30-03:30). NightOwl 02:00-04:00 minus the
            // 02:30-03:30 lock = 3600s. total = 1800+3600 = 5400s.
            SelfTest.expectEqual(b.t, 5400, "day B total")
            SelfTest.expectEqual(b.top.map(\.name), ["NightOwl", "Editor"], "day B ranking")
            SelfTest.expectEqual(b.top.map(\.seconds), [3600, 1800], "day B seconds")

            SelfTest.expect(days["com.apple.finder"] == nil, "finder must never appear as a day key (sanity: wrong-key bug guard)")

            // minSeconds threshold: a day whose total is below the
            // threshold must not appear in the output at all.
            var thresholdSettings = scenario.settings
            thresholdSettings.minSeconds = 999_999
            let filtered = Aggregator.collect(usage: usage, locked: locked, settings: thresholdSettings, calendar: scenario.calendar)
            SelfTest.expect(filtered.isEmpty, "minSeconds above every day's total must produce an empty result, got \(filtered.keys.sorted())")

            // Empty input -> empty output, no crash.
            let empty = Aggregator.collect(usage: [], locked: [], settings: scenario.settings, calendar: scenario.calendar)
            SelfTest.expect(empty.isEmpty, "empty input must produce empty output")
        }
    }
}
