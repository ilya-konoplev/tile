import Foundation

/// Stage 4: `Settings` serialization roundtrip and `SettingsStore`
/// filter-toggle/candidate-list logic – the pieces of the settings
/// window that don't require AppKit/SwiftUI (window chrome, live FDA
/// probing, SMAppService) and so can run headlessly here, same as every
/// other suite (see `SelfTestHarness.swift` for why there's no XCTest).
enum SettingsStoreTests {
    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("settingsstore-test-\(UUID().uuidString).json")
    }

    static func run() {
        SelfTest.suite("Settings serialization") {
            var s = Settings()
            s.widgetEnabled = false
            s.launchAtLogin = true
            s.mode = .allow
            s.apps = FilterLists(allow: ["com.apple.Terminal"], deny: ["com.apple.finder"])
            s.sites = FilterLists(allow: ["github.com"], deny: ["localhost"])
            s.names = ["com.apple.Terminal": "Terminal"]
            s.accent = "#10b981"
            s.showLegend = false
            s.cellSize = 18
            s.minSeconds = 120

            let data = try! JSONEncoder().encode(s)
            let decoded = try! JSONDecoder().decode(Settings.self, from: data)
            SelfTest.expectEqual(decoded, s, "Settings roundtrips through JSON unchanged")

            // Field-level spot checks so a future field-name typo in the
            // Codable synthesis shows up as a readable failure, not just
            // "not equal".
            let json = String(data: data, encoding: .utf8) ?? ""
            for key in ["widgetEnabled", "launchAtLogin", "mode", "apps", "sites", "names", "accent", "showLegend", "cellSize", "minSeconds"] {
                SelfTest.expect(json.contains(key), "settings.json contains key \"\(key)\"")
            }
        }

        SelfTest.suite("Settings.load") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            // Missing file -> defaults, not a crash.
            SelfTest.expectEqual(Settings.load(url: url), Settings(), "missing settings.json falls back to defaults")

            // Malformed file -> defaults too.
            try! Data("not json".utf8).write(to: url)
            SelfTest.expectEqual(Settings.load(url: url), Settings(), "malformed settings.json falls back to defaults")

            // Valid file roundtrips through the same path SettingsStore uses.
            var s = Settings()
            s.accent = "#3b82f6"
            s.cellSize = 30
            try! JSONEncoder().encode(s).write(to: url)
            SelfTest.expectEqual(Settings.load(url: url), s, "valid settings.json loads back exactly")
        }

        SelfTest.suite("SettingsStore atomic write + reload") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let store = SettingsStore(url: url)
            store.setWidgetEnabled(false)
            store.setAccent("#f59e0b")
            store.setCellSize(28)
            store.setShowLegend(false)

            let reloaded = Settings.load(url: url)
            SelfTest.expectEqual(reloaded.widgetEnabled, false, "widgetEnabled persisted")
            SelfTest.expectEqual(reloaded.accent, "#f59e0b", "accent persisted")
            SelfTest.expectEqual(reloaded.cellSize, 28, "cellSize persisted")
            SelfTest.expectEqual(reloaded.showLegend, false, "showLegend persisted")
        }

        SelfTest.suite("SettingsStore.setTracked – deny mode") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            var seed = Settings()
            seed.mode = .deny
            seed.apps = FilterLists(allow: [], deny: ["com.apple.finder"])
            try! JSONEncoder().encode(seed).write(to: url)

            let store = SettingsStore(url: url)
            SelfTest.expectEqual(store.isTracked("com.apple.Terminal", kind: .app), true, "not in deny list -> tracked")
            SelfTest.expectEqual(store.isTracked("com.apple.finder", kind: .app), false, "in deny list -> not tracked")

            // Turn a tracked app off: deny mode appends to deny.
            store.setTracked("com.apple.Terminal", kind: .app, on: false)
            SelfTest.expectEqual(store.settings.apps.deny.contains("com.apple.Terminal"), true, "toggling off in deny mode appends to deny")
            SelfTest.expectEqual(store.isTracked("com.apple.Terminal", kind: .app), false, "now reads as not tracked")

            // Turn a denied app back on: deny mode removes from deny.
            store.setTracked("com.apple.finder", kind: .app, on: true)
            SelfTest.expectEqual(store.settings.apps.deny.contains("com.apple.finder"), false, "toggling on in deny mode removes from deny")
            SelfTest.expectEqual(store.isTracked("com.apple.finder", kind: .app), true, "now reads as tracked")
        }

        SelfTest.suite("SettingsStore.setTracked – allow mode") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            var seed = Settings()
            seed.mode = .allow
            seed.sites = FilterLists(allow: ["github.com"], deny: [])
            try! JSONEncoder().encode(seed).write(to: url)

            let store = SettingsStore(url: url)
            SelfTest.expectEqual(store.isTracked("github.com", kind: .site), true, "in allow list -> tracked")
            SelfTest.expectEqual(store.isTracked("youtube.com", kind: .site), false, "not in allow list -> not tracked")

            store.setTracked("youtube.com", kind: .site, on: true)
            SelfTest.expectEqual(store.settings.sites.allow.contains("youtube.com"), true, "toggling on in allow mode appends to allow")

            store.setTracked("github.com", kind: .site, on: false)
            SelfTest.expectEqual(store.settings.sites.allow.contains("github.com"), false, "toggling off in allow mode removes from allow")
            SelfTest.expectEqual(store.isTracked("github.com", kind: .site), false, "now reads as not tracked")
        }

        SelfTest.suite("SettingsStore.addManual") {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = SettingsStore(url: url)

            store.addManual("  com.apple.Music  ", kind: .app)
            SelfTest.expectEqual(store.settings.apps.deny.contains("com.apple.Music"), false, "manually added app not in deny")
            SelfTest.expectEqual(store.isTracked("com.apple.Music", kind: .app), true, "manually added app reads as tracked")

            store.addManual("   ", kind: .site)
            SelfTest.expectEqual(store.candidates(kind: .site).contains { $0.key == "   " || $0.key.isEmpty }, false, "blank manual entry ignored")

            store.addManual("example.com", kind: .site)
            SelfTest.expect(store.candidates(kind: .site).contains { $0.key == "example.com" }, "manually added site shows up in candidates")
        }

        SelfTest.suite("SettingsStore.classify") {
            // No longer used by candidates(kind:) – see Catalog-backed
            // suite below – but kept as a documented fallback, so its own
            // behaviour still gets covered directly.
            SelfTest.expectEqual(SettingsStore.classify("com.apple.Terminal"), .app, "reverse-DNS bundle id -> app")
            SelfTest.expectEqual(SettingsStore.classify("ru.keepcoder.Telegram"), .app, "3-segment ru.* bundle id -> app")
            SelfTest.expectEqual(SettingsStore.classify("org.m0k.transmission"), .app, "org.* bundle id -> app")
            SelfTest.expectEqual(SettingsStore.classify("github.com"), .site, "2-segment domain ending in .com -> site")
            SelfTest.expectEqual(SettingsStore.classify("aliexpress.ru"), .site, "2-segment domain ending in .ru -> site (not confused with ru.* bundle ids)")
            SelfTest.expectEqual(SettingsStore.classify("notebooklm.google.com"), .site, "3-segment domain ending in .com -> site")
            SelfTest.expectEqual(SettingsStore.classify("nodotsatall"), .app, "no dot -> defaults to app")
        }

        SelfTest.suite("SettingsStore.candidates") {
            let url = tempURL()
            let catalogURL = tempURL()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: catalogURL)
            }
            var seed = Settings()
            seed.apps = FilterLists(allow: ["com.apple.Terminal"], deny: ["com.apple.finder"])
            seed.sites = FilterLists(allow: ["github.com"], deny: [])
            seed.names = [
                "org.videolan.vlc": "VLC",
                "www.youtube.com": "YouTube",
                "com.apple.Terminal": "Terminal",
            ]
            try! JSONEncoder().encode(seed).write(to: url)

            // Candidates not already explicit in apps/sites come from the
            // catalog now, not from guessing at `names` keys – kind is
            // whatever the catalog recorded (from the stream), not a
            // string-shape guess.
            let catalogSeed: [String: CatalogEntry] = [
                "org.videolan.vlc": CatalogEntry(id: "org.videolan.vlc", kind: .app, name: "VLC", seconds: 120, lastSeen: "2026-07-01"),
                "www.youtube.com": CatalogEntry(id: "www.youtube.com", kind: .site, name: "YouTube", seconds: 300, lastSeen: "2026-07-02"),
            ]
            try! JSONEncoder().encode(catalogSeed).write(to: catalogURL)

            let store = SettingsStore(url: url, catalogURL: catalogURL)

            let apps = store.candidates(kind: .app)
            let sites = store.candidates(kind: .site)

            SelfTest.expect(apps.contains { $0.key == "com.apple.Terminal" }, "explicit allow-listed app present")
            SelfTest.expect(apps.contains { $0.key == "com.apple.finder" }, "explicit deny-listed app present")
            SelfTest.expect(apps.contains { $0.key == "org.videolan.vlc" }, "catalog .app entry recovered")
            SelfTest.expectEqual(apps.filter { $0.key == "com.apple.Terminal" }.count, 1, "no duplicate for a key present in both allow/deny and catalog")

            SelfTest.expect(sites.contains { $0.key == "github.com" }, "explicit allow-listed site present")
            SelfTest.expect(sites.contains { $0.key == "www.youtube.com" }, "catalog .site entry recovered")
            SelfTest.expect(!sites.contains { $0.key == "org.videolan.vlc" }, "catalog .app entry does not leak into sites")
            SelfTest.expect(!apps.contains { $0.key == "www.youtube.com" }, "catalog .site entry does not leak into apps")

            // Display names still resolve through Aggregator.displayName
            // using live settings.names, not the name frozen in the
            // catalog entry at write time.
            let vlc = apps.first { $0.key == "org.videolan.vlc" }
            SelfTest.expectEqual(vlc?.displayName, "VLC", "candidate display name uses names override")
            let yt = sites.first { $0.key == "www.youtube.com" }
            SelfTest.expectEqual(yt?.displayName, "YouTube", "site candidate display name uses names override")
        }

        SelfTest.suite("SettingsStore.candidates – kind from catalog, not string shape") {
            // The old heuristic misclassified nothing in the 22-entry real
            // config.json, but it's still a guess: a two-segment bundle id
            // that happens to end in a TLD-shaped word would have been
            // misfiled as a site. The catalog carries the real kind from
            // the stream, so this can't happen anymore.
            let url = tempURL()
            let catalogURL = tempURL()
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: catalogURL)
            }
            let catalogSeed: [String: CatalogEntry] = [
                // classify("com.example.io") would have said .app anyway (3
                // segments, first is a TLD-ish word) – pick a genuinely
                // ambiguous-looking id instead: ends in ".app", a TLD in
                // the heuristic's table, but is in fact a *bundle id* here.
                "widget.example.app": CatalogEntry(id: "widget.example.app", kind: .app, name: "Widget", seconds: 10, lastSeen: "2026-07-01"),
            ]
            try! JSONEncoder().encode(catalogSeed).write(to: catalogURL)
            let store = SettingsStore(url: url, catalogURL: catalogURL)

            SelfTest.expectEqual(SettingsStore.classify("widget.example.app"), .site, "heuristic alone would misfile this as a site")
            SelfTest.expect(store.candidates(kind: .app).contains { $0.key == "widget.example.app" }, "catalog kind (.app, from the stream) wins over the string-shape heuristic")
            SelfTest.expect(!store.candidates(kind: .site).contains { $0.key == "widget.example.app" }, "does not also leak into the site list")
        }
    }
}
