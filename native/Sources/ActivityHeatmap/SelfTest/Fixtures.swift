import Foundation

/// Shared scenario used by both `AggregatorTests` (hand-derived expected
/// numbers, checked purely in-process) and `CrossValidationTests` (same
/// data written to a synthetic knowledgeC.db, run through both the Swift
/// and Python engines, and diffed). Keeping one source of truth means the
/// two test suites can't silently drift apart.
///
/// Covers every edge case ARCHITECTURE.md's algorithm section calls out:
/// midnight-crossing interval, overlapping intervals of the same app
/// (union, not sum), webUsage over its browser's foreground (credited),
/// a background tab outside foreground (capped to the intersection), an
/// overnight screen lock (subtracted from the total), and a deny-listed
/// app (excluded entirely).
enum Fixtures {
    struct Event {
        let stream: String
        let value: String?
        let valueInteger: Int?
        let domain: String?
        let start: Date
        let end: Date
    }

    struct Scenario {
        let events: [Event]
        let settings: Settings
        let dayA: String   // "yesterday - 1", ISO
        let dayB: String   // "yesterday", ISO
        let calendar: Calendar
    }

    static func build(now: Date = Date(), calendar: Calendar = .current) -> Scenario {
        let dayAStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -2, to: now)!)
        let dayBStart = calendar.date(byAdding: .day, value: 1, to: dayAStart)!

        func at(_ base: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: base)!
        }

        var events: [Event] = []

        // 1+2. Midnight-crossing interval, PLUS an overlapping interval of
        // the same app entirely within day A (union must dedupe the
        // overlap, not sum it).
        events.append(Event(stream: "/app/usage", value: "com.testApp.Editor", valueInteger: nil, domain: nil,
                             start: at(dayAStart, 23, 30), end: at(dayBStart, 0, 30)))
        events.append(Event(stream: "/app/usage", value: "com.testApp.Editor", valueInteger: nil, domain: nil,
                             start: at(dayAStart, 10, 0), end: at(dayAStart, 10, 40)))
        events.append(Event(stream: "/app/usage", value: "com.testApp.Editor", valueInteger: nil, domain: nil,
                             start: at(dayAStart, 10, 20), end: at(dayAStart, 11, 0)))

        // 3. Browser foreground + webUsage: Safari foreground 09:00-09:10.
        events.append(Event(stream: "/app/usage", value: "com.apple.Safari", valueInteger: nil, domain: nil,
                             start: at(dayAStart, 9, 0), end: at(dayAStart, 9, 10)))
        // github.com tab entirely inside the foreground window -> credited in full.
        events.append(Event(stream: "/app/webUsage", value: "com.apple.Safari", valueInteger: nil, domain: "github.com",
                             start: at(dayAStart, 9, 2), end: at(dayAStart, 9, 8)))
        // Background pinned tab ticking for 2 hours, way outside the 10-minute
        // foreground window -> must be capped to the intersection (10 min),
        // not credited the full 2 hours.
        events.append(Event(stream: "/app/webUsage", value: "com.apple.Safari", valueInteger: nil, domain: "backgroundtab.example.com",
                             start: at(dayAStart, 9, 0), end: at(dayAStart, 11, 0)))

        // 4. Overnight screen lock on day B: NightOwl runs 02:00-04:00,
        // screen is locked 02:30-03:30 in the middle of that -> only 1
        // hour of the 2 should count.
        events.append(Event(stream: "/app/usage", value: "com.testApp.NightOwl", valueInteger: nil, domain: nil,
                             start: at(dayBStart, 2, 0), end: at(dayBStart, 4, 0)))
        events.append(Event(stream: "/device/isLocked", value: nil, valueInteger: 1, domain: nil,
                             start: at(dayBStart, 2, 30), end: at(dayBStart, 3, 30)))

        // 5. Deny-listed app: must not appear anywhere, and must not
        // contribute to the day total either.
        events.append(Event(stream: "/app/usage", value: "com.apple.finder", valueInteger: nil, domain: nil,
                             start: at(dayAStart, 12, 0), end: at(dayAStart, 12, 30)))

        var settings = Settings()
        settings.mode = .deny
        settings.apps = FilterLists(allow: [], deny: ["com.apple.finder"])
        settings.sites = FilterLists(allow: [], deny: [])
        settings.names = [:]
        settings.minSeconds = 60

        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"

        return Scenario(
            events: events,
            settings: settings,
            dayA: f.string(from: dayAStart),
            dayB: f.string(from: dayBStart),
            calendar: calendar
        )
    }
}

extension Fixtures.Event {
    func toUsageRow(calendar: Calendar) -> Knowledge.UsageRow? {
        guard stream != "/device/isLocked" else { return nil }
        guard let value else { return nil }
        return Knowledge.UsageRow(
            stream: stream,
            value: value,
            domain: domain,
            start: start.timeIntervalSince1970 - Knowledge.coreDataEpoch,
            end: end.timeIntervalSince1970 - Knowledge.coreDataEpoch
        )
    }

    func toLockedRow() -> Knowledge.LockedRow? {
        guard stream == "/device/isLocked" else { return nil }
        return Knowledge.LockedRow(
            start: start.timeIntervalSince1970 - Knowledge.coreDataEpoch,
            end: end.timeIntervalSince1970 - Knowledge.coreDataEpoch
        )
    }

    func toSyntheticRow() -> SyntheticKnowledgeDB.Row {
        SyntheticKnowledgeDB.Row(
            stream: stream,
            value: value,
            valueInteger: valueInteger,
            domain: domain,
            start: start.timeIntervalSince1970 - Knowledge.coreDataEpoch,
            end: end.timeIntervalSince1970 - Knowledge.coreDataEpoch
        )
    }
}
