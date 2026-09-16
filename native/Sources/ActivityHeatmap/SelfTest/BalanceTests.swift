import Foundation

/// Tests for the useful/harmful balance: scoring in the aggregator, the
/// signed quartile scale, and the on-disk compatibility of the widened
/// `DayStats`.
enum BalanceTests {
    static func run() {
        scoring()
        defaultHarmful()
        harmfulWeight()
        levels()
        persistence()
        grouping()
        deviceIsolation()
    }

    // MARK: - Default harmful

    /// With `unclassifiedHarmful` on (the shipped default), everything the mac
    /// spent time on counts against the balance until marked useful — and an
    /// explicit `.neutral` is the escape hatch that keeps some time out of it.
    private static func defaultHarmful() {
        SelfTest.suite("Balance/defaultHarmful") {
            let good = "com.example.good"
            let idle = "com.example.idle"
            let doom = "com.example.doom"

            func day(useful: Int, neutral: Int, unclassified: Int) -> DayStats? {
                var settings = Settings()
                settings.minSeconds = 0
                settings.categories = [good: .useful, idle: .neutral]
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "UTC")!
                let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
                    .addingTimeInterval(9 * 3600)
                func row(_ id: String, offset: Double, seconds: Int) -> Knowledge.UsageRow {
                    let start = base.addingTimeInterval(offset).timeIntervalSince1970 - Knowledge.coreDataEpoch
                    return Knowledge.UsageRow(stream: "/app/usage", value: id, domain: nil,
                                              start: start, end: start + Double(seconds))
                }
                let usage = [
                    row(good, offset: 0, seconds: useful),
                    row(idle, offset: 4000, seconds: neutral),
                    row(doom, offset: 8000, seconds: unclassified),
                ]
                return Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal).values.first
            }

            // Unclassified `doom` time lands in destructive, not ignored.
            guard let d = day(useful: 1800, neutral: 600, unclassified: 1200) else {
                SelfTest.expect(false, "expected an aggregated day"); return
            }
            SelfTest.expectEqual(d.useful, 1800, "useful counts the classified-useful app")
            SelfTest.expectEqual(d.destructive, 1200, "unclassified time is harmful by default")
            SelfTest.expectEqual(d.score, 600, "balance = 1800 useful − 1200 default-harmful")
            SelfTest.expectEqual(d.t, 3600, "total counts all three, including neutral")

            // Explicit neutral stays out of the balance even with default-harmful.
            SelfTest.expect(d.useful - d.destructive == 600,
                            "the 600s neutral app contributed nothing to the balance")
        }
    }

    // MARK: - Harmful weight

    /// The weight re-weighs harmful time in the *score* only; the stored
    /// `useful`/`destructive` seconds stay raw so the tooltip breakdown is honest.
    private static func harmfulWeight() {
        SelfTest.suite("Balance/harmfulWeight") {
            let stats = DayStats(t: 5400, top: [], useful: 3600, destructive: 1800)

            SelfTest.expectEqual(stats.weightedScore(1), 1800, "1x reproduces the raw score")
            SelfTest.expectEqual(stats.weightedScore(1), stats.score, "1x == score")
            SelfTest.expectEqual(stats.weightedScore(2), 0, "2x: 3600 − 2·1800 cancels out")
            SelfTest.expectEqual(stats.weightedScore(3), -1800, "3x tips the day negative")
            // Raw fields are untouched by the weight.
            SelfTest.expectEqual(stats.destructive, 1800, "weight does not alter stored seconds")

            // Clamp: a hand-edited weight below 1 or above 5 is pulled into band.
            var s = Settings()
            s.harmfulWeight = 0.1
            SelfTest.expectEqual(s.clampedHarmfulWeight, 1.0, "weight clamps up to 1.0")
            s.harmfulWeight = 99
            SelfTest.expectEqual(s.clampedHarmfulWeight, 5.0, "weight clamps down to 5.0")
        }
    }

    // MARK: - Aggregation

    private static func scoring() {
        SelfTest.suite("Balance/scoring") {
            var settings = Settings()
            settings.minSeconds = 0
            // These cases test explicit classification in isolation, the way
            // the app behaved before default-harmful. Pin the neutral default
            // here so unclassified time contributes nothing; the new
            // default-harmful behaviour has its own test below.
            settings.unclassifiedHarmful = false
            settings.categories = [
                "md.obsidian": .useful,
                "www.youtube.com": .destructive,
            ]

            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            // Fixed mid-day anchor: keeps every interval inside one local day,
            // so nothing here depends on when the test happens to run.
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
                .addingTimeInterval(9 * 3600)

            func row(_ bundle: String, domain: String? = nil, offset: Double, minutes: Double) -> Knowledge.UsageRow {
                let start = day.addingTimeInterval(offset).timeIntervalSince1970 - Knowledge.coreDataEpoch
                return Knowledge.UsageRow(
                    stream: domain == nil ? "/app/usage" : "/app/webUsage",
                    value: bundle,
                    domain: domain,
                    start: start,
                    end: start + minutes * 60
                )
            }

            // 1h Obsidian (useful), 30m YouTube in Safari (harmful),
            // 15m Terminal (unclassified).
            let usage: [Knowledge.UsageRow] = [
                row("md.obsidian", offset: 0, minutes: 60),
                row("com.apple.Safari", offset: 3600, minutes: 30),
                row("com.apple.Safari", domain: "www.youtube.com", offset: 3600, minutes: 30),
                row("com.apple.Terminal", offset: 5400, minutes: 15),
            ]

            let days = Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal)
            guard let stats = days.values.first else {
                SelfTest.expect(false, "expected one aggregated day")
                return
            }

            SelfTest.expectEqual(stats.useful, 3600, "useful = 1h Obsidian")
            SelfTest.expectEqual(stats.destructive, 1800, "harmful = 30m YouTube")
            SelfTest.expectEqual(stats.score, 1800, "balance = +30m")
            // Unclassified time is in the total but in neither bucket – that is
            // the whole point of the neutral default.
            SelfTest.expectEqual(stats.t, 6300, "total still counts the unclassified 15m")

            // Clearing the classification zeroes the balance without touching
            // the total.
            settings.categories = [:]
            let neutral = Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal)
            guard let neutralStats = neutral.values.first else {
                SelfTest.expect(false, "expected one aggregated day (neutral)")
                return
            }
            SelfTest.expectEqual(neutralStats.score, 0, "nothing classified -> zero balance")
            SelfTest.expectEqual(neutralStats.t, stats.t, "total is unaffected by classification")

            // Harmful outweighing useful must go negative, not clamp at zero.
            settings.categories = ["md.obsidian": .destructive, "www.youtube.com": .destructive]
            let bad = Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal)
            SelfTest.expect((bad.values.first?.score ?? 0) < 0, "all-harmful day scores negative")

            // Categories are keyed by identifier, not display name: the same
            // key must classify a site by its domain, not by "youtube.com"
            // after prefix stripping.
            settings.categories = ["youtube.com": .destructive]
            let byStrippedName = Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal)
            SelfTest.expectEqual(byStrippedName.values.first?.destructive, 0,
                                 "display name must not be accepted as an identifier")

            // A browser cannot be classified: its own foreground time is
            // represented in the breakdown by the domains visited inside it
            // (rules 5-6), so it never reaches the scoring map. Marking Safari
            // is silently a no-op – asserted here so the behaviour is at least
            // known and cannot regress unnoticed.
            settings.categories = ["com.apple.Safari": .destructive]
            let browserMarked = Aggregator.collect(usage: usage, locked: [], settings: settings, calendar: cal)
            SelfTest.expectEqual(browserMarked.values.first?.destructive, 0,
                                 "classifying a browser itself has no effect – classify its domains")


        }
    }

    // MARK: - Signed scale

    private static func levels() {
        SelfTest.suite("Balance/levels") {
            func day(_ score: Int) -> DayStats {
                score >= 0
                    ? DayStats(t: abs(score), top: [], useful: score, destructive: 0)
                    : DayStats(t: abs(score), top: [], useful: 0, destructive: -score)
            }

            // Nine magnitudes per side. Deliberately not four: with very few
            // values the 75th percentile lands exactly on the maximum, so the
            // darkest step is unreachable. That is inherent to quartiles (and
            // predates the balance – the single-scale version behaved the same),
            // but it makes a poor test bed. The small-N case is asserted
            // explicitly further down instead.
            let magnitudes = [300, 600, 900, 1800, 2700, 3600, 5400, 7200, 10800]
            var days: [String: DayStats] = [:]
            for (i, m) in magnitudes.enumerated() {
                days["+\(i)"] = day(m)
                days["-\(i)"] = day(-m)
            }
            let th = HeatmapGrid.thresholds(days: days)

            // Positive and negative sides get their own quartiles, so neither
            // flattens the other.
            SelfTest.expect(th.positive.allSatisfy { $0 > 0 }, "positive quartiles are populated")
            SelfTest.expect(th.negative.allSatisfy { $0 > 0 }, "negative quartiles use magnitude")

            let strongGood = HeatmapGrid.level(score: 10800, thresholds: th)
            SelfTest.expectEqual(strongGood.sign, 1, "positive score -> good ramp")
            SelfTest.expectEqual(strongGood.step, 4, "largest positive -> top step")

            let strongBad = HeatmapGrid.level(score: -10800, thresholds: th)
            SelfTest.expectEqual(strongBad.sign, -1, "negative score -> bad ramp")
            SelfTest.expectEqual(strongBad.step, 4, "largest magnitude -> top step")

            let mildGood = HeatmapGrid.level(score: 300, thresholds: th)
            SelfTest.expectEqual(mildGood.sign, 1, "small positive stays positive")
            SelfTest.expect(mildGood.step < strongGood.step, "smaller magnitude -> lower step")

            // Symmetry: equal magnitudes land on the same step on both sides
            // when the two sides are mirror images, as they are here.
            SelfTest.expectEqual(HeatmapGrid.level(score: 2700, thresholds: th).step,
                                 HeatmapGrid.level(score: -2700, thresholds: th).step,
                                 "mirrored magnitudes -> same step")

            // Documented small-N behaviour: with four values the top quartile
            // IS the maximum, so the darkest step cannot be reached. Asserted
            // so that a future change to the scale has to do so knowingly.
            let sparse = HeatmapGrid.thresholds(days: [
                "1": day(600), "2": day(1800), "3": day(3600), "4": day(7200),
            ])
            SelfTest.expectEqual(HeatmapGrid.level(score: 7200, thresholds: sparse).step, 3,
                                 "few days: max lands on step 3, not 4")

            // Zero and nil are the empty tile, never a coloured one.
            SelfTest.expectEqual(HeatmapGrid.level(score: 0, thresholds: th).sign, 0, "zero -> no sign")
            SelfTest.expectEqual(HeatmapGrid.level(score: 0, thresholds: th).step, 0, "zero -> empty step")
            SelfTest.expectEqual(HeatmapGrid.level(score: nil, thresholds: th).step, 0, "no data -> empty step")

            // An all-neutral history must not crash the scale or invent levels.
            let flat = HeatmapGrid.thresholds(days: ["1": DayStats(t: 3600, top: [])])
            SelfTest.expectEqual(HeatmapGrid.level(score: 0, thresholds: flat).step, 0,
                                 "unclassified history stays empty")
        }
    }

    // MARK: - On-disk compatibility

    private static func persistence() {
        SelfTest.suite("Balance/persistence") {
            // A day written before the balance existed must still load – this
            // file is the only copy of history macOS has already pruned.
            let legacy = #"{"t":7200,"top":[["Claude",3600],["VLC",1800]]}"#
            guard let decoded = try? JSONDecoder().decode(DayStats.self, from: Data(legacy.utf8)) else {
                SelfTest.expect(false, "legacy DayStats must still decode")
                return
            }
            SelfTest.expectEqual(decoded.t, 7200, "legacy total preserved")
            SelfTest.expectEqual(decoded.top.count, 2, "legacy top-3 preserved")
            SelfTest.expectEqual(decoded.useful, 0, "missing useful defaults to 0")
            SelfTest.expectEqual(decoded.destructive, 0, "missing harmful defaults to 0")
            SelfTest.expectEqual(decoded.score, 0, "legacy day reads as neutral, not as bad")

            // Round-trip keeps the new fields.
            let fresh = DayStats(t: 7200, top: [TopEntry(name: "Claude", seconds: 3600)],
                                 useful: 3600, destructive: 1200)
            if let data = try? JSONEncoder().encode(fresh),
               let back = try? JSONDecoder().decode(DayStats.self, from: data) {
                SelfTest.expectEqual(back, fresh, "DayStats roundtrip")
                SelfTest.expectEqual(back.score, 2400, "roundtripped balance")
            } else {
                SelfTest.expect(false, "DayStats roundtrip encode/decode")
            }

            // Settings carrying categories must survive the same trip, and a
            // settings file predating them must not lose the rest of its data.
            // ##"..."## delimiter: the hex colour contains `"#`, which would
            // close a plain #"..."# raw string.
            let legacySettings = ##"{"accent":"#10b981","apps":{"allow":["md.obsidian"],"deny":[]}}"##
            if let s = try? JSONDecoder().decode(Settings.self, from: Data(legacySettings.utf8)) {
                SelfTest.expectEqual(s.categories, [:], "missing categories default to empty")
                SelfTest.expectEqual(s.accent, "#10b981", "other settings survive")
                SelfTest.expectEqual(s.accentBad, Settings().accentBad, "missing bad accent defaults")
            } else {
                SelfTest.expect(false, "settings without categories must decode")
            }

            var withCats = Settings()
            withCats.categories = ["md.obsidian": .useful, "www.youtube.com": .destructive]
            if let data = try? JSONEncoder().encode(withCats),
               let back = try? JSONDecoder().decode(Settings.self, from: data) {
                SelfTest.expectEqual(back.categories, withCats.categories, "categories roundtrip")
            } else {
                SelfTest.expect(false, "settings with categories roundtrip")
            }
        }
    }

    // MARK: - Category-grouped lists

    /// The settings screen can group candidates by category. Getting these
    /// queries wrong fails silently – a row simply stops appearing in the
    /// group it belongs to – so they are asserted rather than eyeballed.
    private static func grouping() {
        SelfTest.suite("Balance/grouping") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("balance-grouping-\(UUID().uuidString).json")
            let catalogURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("balance-catalog-\(UUID().uuidString).json")
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: catalogURL)
            }

            // Seed a catalog so the store has candidates to group.
            let entries: [String: CatalogEntry] = [
                "md.obsidian": CatalogEntry(id: "md.obsidian", kind: .app, name: "Obsidian",
                                            seconds: 3600, lastSeen: "2026-07-20"),
                "com.apple.Safari": CatalogEntry(id: "com.apple.Safari", kind: .app, name: "Safari",
                                                 seconds: 7200, lastSeen: "2026-07-20"),
                "www.youtube.com": CatalogEntry(id: "www.youtube.com", kind: .site, name: "youtube.com",
                                                seconds: 1800, lastSeen: "2026-07-20"),
            ]
            let catalog = Catalog(url: catalogURL)
            try? catalog.write(entries)

            let store = SettingsStore(url: url, catalogURL: catalogURL)
            store.setCategory(.useful, for: "md.obsidian")
            store.setCategory(.destructive, for: "www.youtube.com")

            let useful = store.candidates(category: .useful).map(\.key)
            let harmful = store.candidates(category: .destructive).map(\.key)
            let neutral = store.candidates(category: nil).map(\.key)

            SelfTest.expectEqual(useful, ["md.obsidian"], "useful group")
            SelfTest.expectEqual(harmful, ["www.youtube.com"], "harmful group")
            SelfTest.expect(neutral.contains("com.apple.Safari"), "unclassified lands in neutral")
            SelfTest.expect(!neutral.contains("md.obsidian"), "classified item leaves neutral")

            // Every candidate appears in exactly one group – no row can go
            // missing from the settings screen or show up twice.
            let all = Set(store.allCandidates().map(\.key))
            let grouped = useful + harmful + neutral
            SelfTest.expectEqual(Set(grouped), all, "groups cover every candidate")
            SelfTest.expectEqual(grouped.count, all.count, "no candidate appears twice")

            // Apps and sites are mixed in the category view, sorted by the
            // name the user actually sees.
            let names = store.allCandidates().map(\.displayName)
            SelfTest.expectEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                                 "category view is sorted by display name")

            // Clearing a classification returns the row to neutral.
            store.setCategory(nil, for: "md.obsidian")
            SelfTest.expect(store.candidates(category: .useful).isEmpty, "cleared category empties the group")
            SelfTest.expect(store.candidates(category: nil).map(\.key).contains("md.obsidian"),
                            "cleared item returns to neutral")
        }
    }

    // MARK: - Cross-device contamination

    /// knowledgeC is shared across the user's devices. Records synced from an
    /// iPhone land in the same tables with the same stream names, and counting
    /// them cost a real day of history: every `/device/isLocked` row on this
    /// machine turned out to be the *phone's* lock state, and subtracting it
    /// reduced a 7-hour working day to 36 minutes.
    private static func deviceIsolation() {
        SelfTest.suite("Balance/device isolation") {
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let base = cal.startOfDay(for: day).addingTimeInterval(9 * 3600)
            let cd = { (offset: Double) in base.addingTimeInterval(offset).timeIntervalSince1970 - Knowledge.coreDataEpoch }

            // Local: one hour of work. Remote (phone): "locked" that whole hour.
            let rows: [SyntheticKnowledgeDB.Row] = [
                .init(stream: "/app/usage", value: "md.obsidian", valueInteger: nil,
                      domain: nil, start: cd(0), end: cd(3600)),
                .init(stream: "/device/isLocked", value: nil, valueInteger: 1,
                      domain: nil, start: cd(0), end: cd(3600), remoteDevice: true),
            ]

            guard let path = try? SyntheticKnowledgeDB.build(rows: rows) else {
                SelfTest.expect(false, "could not build synthetic db")
                return
            }
            defer { try? FileManager.default.removeItem(atPath: path) }

            guard let loaded = try? Knowledge.loadRows(dbPath: path, cutoff: 0) else {
                SelfTest.expect(false, "could not read synthetic db")
                return
            }

            SelfTest.expectEqual(loaded.usage.count, 1, "local usage row is read")
            SelfTest.expectEqual(loaded.locked.count, 0,
                                 "a remote device's lock periods must be ignored")

            var settings = Settings()
            settings.minSeconds = 0
            let days = Aggregator.collect(usage: loaded.usage, locked: loaded.locked,
                                          settings: settings, calendar: cal)
            SelfTest.expectEqual(days.values.first?.t, 3600,
                                 "the phone being locked must not erase the Mac's hour")
        }
    }
}
