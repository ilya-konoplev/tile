import Foundation

/// Localisation is mostly a table of literals, so only the parts with actual
/// logic are worth testing: Russian's three plural forms, duration units and
/// month names, plus the guarantee that no string is silently empty in either
/// language.
enum LocalizationTests {
    static func run() {
        SelfTest.suite("Localization") { body() }
    }

    private static func body() {
        let ru = L10n(.ru)
        let en = L10n(.en)

        // Russian plurals: 1 день / 2-4 дня / 5-20 дней, with the 11-14
        // exception that catches naive implementations.
        SelfTest.expectEqual(ru.days(1), "1 день", "ru 1")
        SelfTest.expectEqual(ru.days(2), "2 дня", "ru 2")
        SelfTest.expectEqual(ru.days(4), "4 дня", "ru 4")
        SelfTest.expectEqual(ru.days(5), "5 дней", "ru 5")
        SelfTest.expectEqual(ru.days(11), "11 дней", "ru 11 (not 'день')")
        SelfTest.expectEqual(ru.days(12), "12 дней", "ru 12 (not 'дня')")
        SelfTest.expectEqual(ru.days(14), "14 дней", "ru 14")
        SelfTest.expectEqual(ru.days(21), "21 день", "ru 21")
        SelfTest.expectEqual(ru.days(22), "22 дня", "ru 22")
        SelfTest.expectEqual(ru.days(25), "25 дней", "ru 25")
        SelfTest.expectEqual(ru.days(91), "91 день", "ru 91 – the widget's own count")
        SelfTest.expectEqual(ru.days(0), "0 дней", "ru 0")

        SelfTest.expectEqual(en.days(1), "1 day", "en 1")
        SelfTest.expectEqual(en.days(2), "2 days", "en 2")
        SelfTest.expectEqual(en.days(91), "91 days", "en 91")
        SelfTest.expectEqual(en.days(0), "0 days", "en 0")

        // Durations round minutes and drop empty components in both languages.
        SelfTest.expectEqual(ru.duration(0), "0 мин", "ru zero")
        SelfTest.expectEqual(ru.duration(59), "1 мин", "ru rounds up")
        SelfTest.expectEqual(ru.duration(3600), "1 ч", "ru exact hour has no minutes")
        SelfTest.expectEqual(ru.duration(3660), "1 ч 1 мин", "ru hour + minute")
        SelfTest.expectEqual(en.duration(3600), "1 h", "en exact hour")
        SelfTest.expectEqual(en.duration(3660), "1 h 1 min", "en hour + minute")
        // Leftover minutes that round to 60 must carry into the hour, not show
        // as "10 h 60 min" (39599s = 10h 59.98m → rounds to 60).
        SelfTest.expectEqual(en.duration(39599), "11 h", "minutes rounding to 60 carry")
        SelfTest.expectEqual(ru.duration(7199), "2 ч", "ru 59.98m carries to the hour")

        // Dates come from ISO keys, genitive month in Russian.
        SelfTest.expectEqual(ru.date(iso: "2026-07-19"), "19 июля", "ru date")
        SelfTest.expectEqual(ru.date(iso: "2026-01-01"), "1 января", "ru january")
        SelfTest.expectEqual(en.date(iso: "2026-07-19"), "19 July", "en date")
        SelfTest.expectEqual(ru.date(iso: "garbage"), "garbage", "malformed iso passes through")
        SelfTest.expectEqual(ru.date(iso: "2026-13-01"), "2026-13-01", "impossible month passes through")

        // `.system` must resolve to a real language, never stay `.system`.
        SelfTest.expect(Language.system.resolved != .system, "system resolves to a concrete language")
        SelfTest.expectEqual(Language.ru.resolved, .ru, "explicit ru stays ru")
        SelfTest.expectEqual(Language.en.resolved, .en, "explicit en stays en")

        // No user-facing string may be empty in either language – an empty
        // label renders as an invisible control.
        for (name, strings) in [("ru", ru), ("en", en)] {
            let all: [(String, String)] = [
                ("legendNegative", strings.legendNegative),
                ("legendPositive", strings.legendPositive),
                ("totalSuffix", strings.totalSuffix),
                ("scaleHint", strings.scaleHint),
                ("noActivity", strings.noActivity),
                ("loadingBody", strings.loadingBody),
                ("noAccessTitle", strings.noAccessTitle),
                ("noAccessBody", strings.noAccessBody),
                ("failedTitle", strings.failedTitle),
                ("menuWidgetEnabled", strings.menuWidgetEnabled),
                ("menuSettings", strings.menuSettings),
                ("menuQuit", strings.menuQuit),
                ("widgetEnabled", strings.widgetEnabled),
                ("launchAtLogin", strings.launchAtLogin),
                ("accessGranted", strings.accessGranted),
                ("accessDenied", strings.accessDenied),
                ("openSystemSettings", strings.openSystemSettings),
                ("searchPlaceholder", strings.searchPlaceholder),
                ("sectionApps", strings.sectionApps),
                ("sectionSites", strings.sectionSites),
                ("addManually", strings.addManually),
                ("accentColor", strings.accentColor),
                ("widgetScale", strings.widgetScale),
                ("language", strings.language),
                ("languageSystem", strings.languageSystem),
            ]
            for (key, value) in all {
                SelfTest.expect(!value.trimmingCharacters(in: .whitespaces).isEmpty,
                                "\(name).\(key) is non-empty")
            }
        }

        // Russian and English must actually differ where they are meant to –
        // guards against a copy/paste that leaves both sides identical.
        SelfTest.expect(ru.legendNegative != en.legendNegative, "legend differs between languages")
        SelfTest.expect(ru.menuQuit != en.menuQuit, "quit differs between languages")

        // Header shows today's date now – the static title and the day-count
        // pill are gone (the pill counted grid cells, not days with data).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let probe = Date(timeIntervalSince1970: 1_784_000_000)  // 2026-07-14 UTC
        SelfTest.expect(ru.today(probe, calendar: cal).hasPrefix(ru.date(iso: "2026-07-14")),
                        "header line starts with the same date the tooltip uses")
        SelfTest.expect(en.today(probe, calendar: cal).hasPrefix(en.date(iso: "2026-07-14")),
                        "header line starts with the date, English")
        SelfTest.expect(!ru.today().isEmpty && !en.today().isEmpty, "header date is non-empty")
        SelfTest.expect(ru.today(probe, calendar: cal) != en.today(probe, calendar: cal),
                        "header date differs between languages")

        // Weekday is part of the header line: "21 July, Tuesday".
        SelfTest.expectEqual(en.today(probe, calendar: cal), "14 July, Tuesday", "en header line")
        SelfTest.expectEqual(ru.today(probe, calendar: cal), "14 июля, вторник", "ru header line")
        // Every weekday resolves, and Russian stays lowercase while English
        // capitalises – a shared list with `.capitalized` would break one of them.
        for offset in 0..<7 {
            let d = cal.date(byAdding: .day, value: offset, to: probe)!
            let ruLine = ru.today(d, calendar: cal)
            let enLine = en.today(d, calendar: cal)
            SelfTest.expect(ruLine.contains(", ") && enLine.contains(", "),
                            "weekday present for offset \(offset)")
            let ruWeekday = String(ruLine.split(separator: " ").last!)
            SelfTest.expect(ruWeekday.first?.isLowercase == true,
                            "ru weekday stays lowercase: \(ruWeekday)")
            let enWeekday = String(enLine.split(separator: " ").last!)
            SelfTest.expect(enWeekday.first?.isUppercase == true,
                            "en weekday is capitalised: \(enWeekday)")
        }
    }
}

/// Guards the settings format against the failure mode that adding
/// `language` introduced: a synthesised `Codable` throws on any missing key,
/// and `Settings.load()` swallows that into silent defaults – so one new
/// field would wipe every existing user's filters.
enum SettingsCompatTests {
    static func run() {
        // A settings.json written before `language` and `scale` existed.
        let legacy = """
        {"widgetEnabled":false,"launchAtLogin":true,"mode":"allow",
         "apps":{"allow":["md.obsidian"],"deny":[]},
         "sites":{"allow":[],"deny":["localhost"]},
         "names":{"md.obsidian":"Obsidian"},
         "accent":"#10b981","showLegend":false,"cellSize":30,"minSeconds":120}
        """
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: Data(legacy.utf8)) else {
            SelfTest.expect(false, "legacy settings.json must still decode")
            return
        }
        SelfTest.expectEqual(decoded.accent, "#10b981", "legacy accent preserved")
        SelfTest.expectEqual(decoded.apps.allow, ["md.obsidian"], "legacy filters preserved")
        SelfTest.expectEqual(decoded.names["md.obsidian"], "Obsidian", "legacy names preserved")
        SelfTest.expectEqual(decoded.cellSize, 30, "legacy cellSize preserved")
        SelfTest.expectEqual(decoded.minSeconds, 120, "legacy minSeconds preserved")
        SelfTest.expect(!decoded.widgetEnabled, "legacy widgetEnabled preserved")
        // …and the fields that did not exist back then get their defaults.
        SelfTest.expectEqual(decoded.language, .system, "missing language defaults")
        SelfTest.expectEqual(decoded.scale, 1.0, "missing scale defaults")

        // An empty object must yield pure defaults rather than throwing.
        let empty = try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        SelfTest.expectEqual(empty, Settings(), "empty object decodes to defaults")

        // Round-trip keeps everything.
        var custom = Settings()
        custom.language = .en
        custom.scale = 0.75
        custom.accent = "#3b82f6"
        if let data = try? JSONEncoder().encode(custom),
           let back = try? JSONDecoder().decode(Settings.self, from: data) {
            SelfTest.expectEqual(back, custom, "settings roundtrip")
        } else {
            SelfTest.expect(false, "settings roundtrip encode/decode")
        }
    }
}
