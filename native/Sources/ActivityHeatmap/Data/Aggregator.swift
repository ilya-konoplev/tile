import Foundation

/// A single top-3 breakdown entry. Serializes as a bare 2-element JSON
/// array `["Claude", 8400]`, matching the Übersicht widget's
/// `activity.json`, *not* as a `{"name":...,"seconds":...}` object.
struct TopEntry: Equatable {
    let name: String
    let seconds: Int
}

extension TopEntry: Codable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
        seconds = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(name)
        try container.encode(seconds)
    }
}

/// One line of a day's *full* breakdown, for the click-to-open day detail.
/// Unlike `TopEntry` it carries the `key` (bundle id / domain) so the detail
/// view can look up the identifier's *current* category and colour it live —
/// storing the category here would go stale the moment the user reclassifies.
///
/// Serialises as a compact 3-element array `["com.apple.Safari","Safari",1234]`,
/// same spirit as `TopEntry`, to keep `activity.json` small across ~30 entries
/// a day × 91 days.
struct BreakdownEntry: Equatable {
    let key: String
    let name: String
    let seconds: Int
}

extension BreakdownEntry: Codable {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        key = try c.decode(String.self)
        name = try c.decode(String.self)
        seconds = try c.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(key)
        try c.encode(name)
        try c.encode(seconds)
    }
}

struct DayStats: Equatable {
    /// Total tracked, awake time for the day, in seconds. Independent of
    /// categories – this is "how long was the mac in use".
    let t: Int
    let top: [TopEntry]
    /// The day's full per-identifier breakdown (all apps/sites with time on it,
    /// most first), for the click-to-open detail. Empty for days written before
    /// this existed — those keep only `top`, and their full list is
    /// unrecoverable (knowledgeC.db is long pruned). Bounded on write so a busy
    /// day can't bloat the file.
    let breakdown: [BreakdownEntry]
    /// Seconds spent on identifiers marked `.useful` / `.destructive`.
    /// Anything unclassified is in `t` but in neither of these.
    let useful: Int
    let destructive: Int

    /// The day's balance: useful minus destructive, 1:1. Positive days are
    /// drawn in the good ramp, negative in the bad one; zero reads as empty.
    var score: Int { useful - destructive }

    /// The balance that drives tile colour and the legend figure, with harmful
    /// time weighted. `weight` 1.0 reproduces `score` exactly. Kept separate
    /// from the stored `useful`/`destructive` (which stay raw seconds) so the
    /// tooltip breakdown stays honest while the colour reflects the weighting.
    func weightedScore(_ weight: Double) -> Int {
        useful - Int((Double(destructive) * weight).rounded())
    }

    init(t: Int, top: [TopEntry], breakdown: [BreakdownEntry] = [], useful: Int = 0, destructive: Int = 0) {
        self.t = t
        self.top = top
        self.breakdown = breakdown
        self.useful = useful
        self.destructive = destructive
    }
}

extension DayStats: Codable {
    /// Tolerant decoding, for the same reason `Settings` has one: `activity.json`
    /// is the only surviving copy of history macOS has already pruned, and a
    /// synthesised `Codable` throws on missing keys. Days written before
    /// categories existed decode with a zero balance instead of taking the
    /// whole file down with them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Int.self, forKey: .t)
        top = try c.decodeIfPresent([TopEntry].self, forKey: .top) ?? []
        breakdown = try c.decodeIfPresent([BreakdownEntry].self, forKey: .breakdown) ?? []
        useful = try c.decodeIfPresent(Int.self, forKey: .useful) ?? 0
        destructive = try c.decodeIfPresent(Int.self, forKey: .destructive) ?? 0
    }
}

struct ActivitySnapshot: Codable, Equatable {
    let generated: String
    var days: [String: DayStats]
}

/// Builds a day -> DayStats map from raw knowledgeC.db rows. Port of
/// `collect()` in the Python prototype's `aggregate.py` – see
/// ARCHITECTURE.md "Алгоритм агрегации" for the numbered rules this follows.
enum Aggregator {
    /// Splits `[start, end)` across local-midnight boundaries. Yields
    /// (local calendar day, piece start, piece end) triples whose pieces
    /// concatenate back to the original interval. Port of `split_by_day`.
    static func splitByDay(start: Date, end: Date, calendar: Calendar = .current) -> [(day: String, start: Date, end: Date)] {
        var out: [(day: String, start: Date, end: Date)] = []
        var cursor = start
        let formatter = Self.dayFormatter(calendar: calendar)
        while cursor < end {
            let startOfDay = calendar.startOfDay(for: cursor)
            let midnight = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? end
            let pieceEnd = Swift.min(end, midnight)
            out.append((formatter.string(from: cursor), cursor, pieceEnd))
            cursor = pieceEnd
        }
        return out
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// `com.apple.Safari` -> `Safari`; webUsage domains drop a leading
    /// `www.`; explicit `names` overrides win over both. Port of
    /// `display_name`.
    static func displayName(_ value: String, isWeb: Bool, overrides: [String: String]) -> String {
        if let override = overrides[value] {
            return override
        }
        if isWeb {
            return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
        }
        if let lastDot = value.lastIndex(of: ".") {
            return String(value[value.index(after: lastDot)...])
        }
        return value
    }

    /// `now` and `calendar` are injectable for tests; production callers
    /// use the defaults (wall-clock time, local calendar).
    static func collect(
        usage: [Knowledge.UsageRow],
        locked: [Knowledge.LockedRow],
        settings: Settings,
        calendar: Calendar = .current
    ) -> [String: DayStats] {
        // Screen-locked windows, split across local midnight the same way
        // as everything else.
        var lockedByDay: [String: [Intervals.Interval]] = [:]
        for row in locked {
            let start = Date(timeIntervalSince1970: row.start + Knowledge.coreDataEpoch)
            let end = Date(timeIntervalSince1970: row.end + Knowledge.coreDataEpoch)
            for piece in splitByDay(start: start, end: end, calendar: calendar) {
                lockedByDay[piece.day, default: []].append((piece.start.timeIntervalSince1970, piece.end.timeIntervalSince1970))
            }
        }

        // Any bundle id seen in webUsage is a browser: represented in the
        // breakdown by its domains instead of itself, so time is not
        // double counted. Built from *all* raw rows, before filtering –
        // matches the Python reference exactly.
        let browsers = Set(usage.filter { $0.stream == "/app/webUsage" }.map { $0.value })

        // Keyed by raw identifier (bundle id / domain), NOT by display name:
        // categories are assigned per identifier, and display names are not
        // unique. Names are resolved once at the end, for the top-3 only.
        var perApp: [String: [String: [Intervals.Interval]]] = [:]        // day -> bundle id -> intervals
        // day -> browser bundle id -> domain -> intervals. The browser is kept
        // because a domain may only be credited while ITS OWN browser was
        // frontmost – merging every browser's foreground into one pool let a
        // page in Safari collect time while Chrome was the active app.
        var perWeb: [String: [String: [String: [Intervals.Interval]]]] = [:]
        var displayNames: [String: String] = [:]                          // identifier -> display name
        var spans: [String: [Intervals.Interval]] = [:]                   // day -> intervals (overall total)
        var foreground: [String: [String: [Intervals.Interval]]] = [:]    // day -> browser bundle id -> intervals

        for row in usage {
            let isWeb = row.stream == "/app/webUsage"
            let key: String? = isWeb ? row.domain : row.value
            guard let key else { continue }
            let list = isWeb ? settings.sites : settings.apps
            guard settings.keeps(key, in: list) else { continue }

            let start = Date(timeIntervalSince1970: row.start + Knowledge.coreDataEpoch)
            let end = Date(timeIntervalSince1970: row.end + Knowledge.coreDataEpoch)
            displayNames[key] = displayName(key, isWeb: isWeb, overrides: settings.names)

            for piece in splitByDay(start: start, end: end, calendar: calendar) {
                let interval: Intervals.Interval = (piece.start.timeIntervalSince1970, piece.end.timeIntervalSince1970)
                if isWeb {
                    perWeb[piece.day, default: [:]][row.value, default: [:]][key, default: []].append(interval)
                    continue
                }
                // Only foreground app usage defines the day's total;
                // webUsage keeps ticking for background tabs.
                spans[piece.day, default: []].append(interval)
                if browsers.contains(row.value) {
                    foreground[piece.day, default: [:]][row.value, default: []].append(interval)
                } else {
                    perApp[piece.day, default: [:]][key, default: []].append(interval)
                }
            }
        }

        var days: [String: DayStats] = [:]
        for (day, intervals) in spans {
            let holes = Intervals.merge(lockedByDay[day] ?? [])
            let total = Intervals.awakeDuration(intervals, holes)
            if total < Double(settings.minSeconds) { continue }

            var scored: [String: Double] = [:]   // identifier -> awake seconds
            for (key, iv) in perApp[day] ?? [:] {
                scored[key] = Intervals.awakeDuration(iv, holes)
            }
            // A domain only counts while its own browser was frontmost, and
            // simultaneous tabs share that time instead of each claiming all
            // of it. webUsage keeps ticking for every open tab, so without the
            // split an hour with two tabs open counted as an hour for each –
            // measured at 26% over the day's real total on 2026-07-15, and it
            // let a pinned harmful tab cancel out real work.
            for (browser, domains) in perWeb[day] ?? [:] {
                let browserTime = Intervals.merge(foreground[day]?[browser] ?? [])
                let eligible = domains.mapValues {
                    Intervals.subtract(Intervals.intersect($0, browserTime), holes)
                }
                for (key, seconds) in Aggregator.shareOverlap(eligible) {
                    scored[key, default: 0] += seconds
                }
            }

            // Balance split. `effectiveCategory` decides where unclassified time
            // goes — harmful by default now (`unclassifiedHarmful`), so most of
            // `total` lands in `destructive` until the user marks things useful.
            // The harmful WEIGHT is deliberately NOT applied here: `useful` and
            // `destructive` stay raw seconds so the tooltip's +/− breakdown
            // reads as real time; the weight is applied later, on the score
            // (`DayStats.weightedScore`).
            var useful = 0.0
            var destructive = 0.0
            for (key, seconds) in scored {
                switch settings.effectiveCategory(of: key) {
                case .useful: useful += seconds
                case .neutral: break
                case .destructive: destructive += seconds
                }
            }

            let ranked = scored.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key // stable, deterministic tiebreak; Python's sort is stable on insertion order instead (see report)
            }
            let positive = ranked.filter { $0.value > 0 }
            let top = positive.prefix(3).map {
                TopEntry(name: displayNames[$0.key] ?? $0.key, seconds: Int($0.value.rounded()))
            }
            // Full breakdown for the day-detail popover. Capped at 50 — far more
            // than anyone reads, but a bound so a pathological day can't bloat
            // the file. Carries the key so the detail view colours each row by
            // the identifier's *current* category.
            let breakdown = positive.prefix(50).map {
                BreakdownEntry(
                    key: $0.key,
                    name: displayNames[$0.key] ?? $0.key,
                    seconds: Int($0.value.rounded())
                )
            }
            days[day] = DayStats(
                t: Int(total.rounded()),
                top: Array(top),
                breakdown: Array(breakdown),
                useful: Int(useful.rounded()),
                destructive: Int(destructive.rounded())
            )
        }
        return days
    }


    /// Splits time covered by several domains at once evenly between them.
    ///
    /// `/app/webUsage` reports every open tab, not just the visible one, so a
    /// single wall-clock second can be claimed by many domains. Counting each
    /// in full breaks the invariant that per-domain time sums to at most the
    /// browser's own foreground time – and worse, let a pinned tab marked
    /// harmful cancel out an hour of real work.
    ///
    /// Which tab was actually being looked at is not recorded anywhere, so an
    /// even split is a deliberate guess. It is the bounded one: the shares
    /// always add back up to the real elapsed time, where the previous
    /// behaviour could exceed it several times over.
    ///
    /// Sweep line over every boundary; each elementary segment is divided by
    /// the number of domains covering it.
    static func shareOverlap(_ perDomain: [String: [Intervals.Interval]]) -> [String: Double] {
        let merged = perDomain.mapValues { Intervals.merge($0) }
        var bounds: Set<Double> = []
        for intervals in merged.values {
            for interval in intervals {
                bounds.insert(interval.0)
                bounds.insert(interval.1)
            }
        }
        guard bounds.count > 1 else { return perDomain.mapValues { _ in 0 } }

        let points = bounds.sorted()
        var result: [String: Double] = perDomain.mapValues { _ in 0 }
        for i in 0..<(points.count - 1) {
            let (from, to) = (points[i], points[i + 1])
            let length = to - from
            guard length > 0 else { continue }
            // Half-open probe inside the segment avoids boundary ambiguity.
            let probe = from + length / 2
            let covering = merged.filter { _, intervals in
                intervals.contains { $0.0 <= probe && probe < $0.1 }
            }
            guard !covering.isEmpty else { continue }
            let share = length / Double(covering.count)
            for key in covering.keys {
                result[key, default: 0] += share
            }
        }
        return result
    }

    /// Builds the raw-identifier catalog (ARCHITECTURE.md "Каталог
    /// идентификаторов") from the same raw rows `collect()` consumes.
    ///
    /// Deliberately does **not** apply `settings.keeps` filtering: the
    /// whole point of the catalog is to answer "what identifiers have
    /// actually shown up in the data", including ones currently denied –
    /// otherwise a denied id would vanish from the settings window's
    /// candidate list the moment it got denied. `kind` comes straight from
    /// which stream a row was read on (`/app/usage` -> `.app`,
    /// `/app/webUsage` -> `.site`), never guessed from the string's shape.
    /// `seconds` is the awake-duration total for the days visible in this
    /// particular scan (same day-bucketed union/lock-subtraction as
    /// `collect()`) – like `DayStats.t`, it reflects "what the current
    /// scan of the live db shows", not a running lifetime total; `Catalog`
    /// (Data/Catalog.swift) is what makes that survive db pruning across
    /// refreshes, the same way `Store` does for day totals.
    static func collectCatalog(
        usage: [Knowledge.UsageRow],
        locked: [Knowledge.LockedRow],
        settings: Settings,
        calendar: Calendar = .current
    ) -> [String: CatalogEntry] {
        var lockedByDay: [String: [Intervals.Interval]] = [:]
        for row in locked {
            let start = Date(timeIntervalSince1970: row.start + Knowledge.coreDataEpoch)
            let end = Date(timeIntervalSince1970: row.end + Knowledge.coreDataEpoch)
            for piece in splitByDay(start: start, end: end, calendar: calendar) {
                lockedByDay[piece.day, default: []].append((piece.start.timeIntervalSince1970, piece.end.timeIntervalSince1970))
            }
        }

        var kinds: [String: CatalogKind] = [:]
        var perDayId: [String: [String: [Intervals.Interval]]] = [:]   // day -> id -> intervals
        var lastSeenDay: [String: String] = [:]

        for row in usage {
            let isWeb = row.stream == "/app/webUsage"
            let key: String? = isWeb ? row.domain : row.value
            guard let key else { continue }
            kinds[key] = isWeb ? .site : .app

            let start = Date(timeIntervalSince1970: row.start + Knowledge.coreDataEpoch)
            let end = Date(timeIntervalSince1970: row.end + Knowledge.coreDataEpoch)
            for piece in splitByDay(start: start, end: end, calendar: calendar) {
                let interval: Intervals.Interval = (piece.start.timeIntervalSince1970, piece.end.timeIntervalSince1970)
                perDayId[piece.day, default: [:]][key, default: []].append(interval)
                if lastSeenDay[key] == nil || piece.day > lastSeenDay[key]! {
                    lastSeenDay[key] = piece.day
                }
            }
        }

        var totalSeconds: [String: Int] = [:]
        for (day, byId) in perDayId {
            let holes = Intervals.merge(lockedByDay[day] ?? [])
            for (key, intervals) in byId {
                totalSeconds[key, default: 0] += Int(Intervals.awakeDuration(intervals, holes).rounded())
            }
        }

        var out: [String: CatalogEntry] = [:]
        for (key, kind) in kinds {
            out[key] = CatalogEntry(
                id: key,
                kind: kind,
                name: displayName(key, isWeb: kind == .site, overrides: settings.names),
                seconds: totalSeconds[key] ?? 0,
                lastSeen: lastSeenDay[key] ?? ""
            )
        }
        return out
    }
}
