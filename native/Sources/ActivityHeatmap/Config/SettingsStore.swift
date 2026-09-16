import Foundation
import ServiceManagement

enum FilterKind {
    case app
    case site
}

/// A candidate row for the "Приложения и сайты" list: an identifier
/// (bundle id for `.app`, domain for `.site`) plus its resolved display
/// name.
struct FilterCandidate: Identifiable, Equatable {
    let key: String
    let kind: FilterKind
    let displayName: String
    var id: String { key }
}

/// Single source of truth for `Settings`, shared by the menu bar item and
/// the settings window so "Виджет включён" always agrees between the two
/// – the tray toggle and the settings toggle must never disagree.
///
/// Every mutation writes `settings.json` atomically (same temp-file +
/// `replaceItem` pattern as `Store.write` for `activity.json` – small
/// file, but there is no reason to be less careful about torn writes
/// here than there).
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: Settings

    private let url: URL
    private let catalog: Catalog

    /// Fired after a mutation that can change *which* apps/sites get
    /// counted (filter toggles, manual adds) – not for purely cosmetic
    /// changes (accent, cellSize, showLegend, widgetEnabled) – so the
    /// owner can kick an immediate re-aggregation instead of waiting for
    /// the hourly timer.
    var onFilterSettingsChanged: (() -> Void)?

    init(url: URL = Settings.defaultURL, catalogURL: URL = Catalog.defaultURL) {
        self.url = url
        self.catalog = Catalog(url: catalogURL)
        self.settings = Settings.load(url: url)
    }

    private func mutate(_ body: (inout Settings) -> Void) {
        var copy = settings
        body(&copy)
        settings = copy
        save()
    }

    private func save() {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            let tmp = dir.appendingPathComponent(url.lastPathComponent + ".tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, options: [], resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            appLog("SettingsStore: save failed: \(error)")
        }
    }

    // MARK: - Main screen

    func setWidgetEnabled(_ on: Bool) {
        mutate { $0.widgetEnabled = on }
    }

    /// `SMAppService.register()`/`unregister()` are real, user-visible
    /// system side effects (they add/remove a login item). This must only
    /// ever be called from a direct user click on the toggle – never at
    /// startup, never "just to check" –
    /// so this method is the *only* call site and is itself only wired
    /// to the settings-window switch, nowhere else. Returns an error to
    /// display inline on failure instead of throwing, since the caller
    /// is a SwiftUI Binding setter that can't propagate one.
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> Error? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            mutate { $0.launchAtLogin = on }
            return nil
        } catch {
            appLog("SettingsStore: SMAppService \(on ? "register" : "unregister") failed: \(error)")
            return error
        }
    }

    func setAccent(_ hex: String) {
        mutate { $0.accent = hex }
    }

    func setCellSize(_ size: Int) {
        mutate { $0.cellSize = size }
    }

    /// Proportional widget scale. Clamped to the same range `HeatmapMetrics`
    /// enforces, so a hand-edited settings.json can't produce a window the
    /// user cannot reach.
    func setScale(_ scale: Double) {
        mutate { $0.scale = min(max(scale, 0.4), 3.0) }
    }

    /// Classifies an identifier, or clears it back to neutral with `nil`.
    /// Changes the balance, so it triggers the same immediate re-aggregation
    /// as a filter change rather than waiting for the hourly timer.
    func setCategory(_ category: Category?, for key: String) {
        mutate { s in
            if let category {
                s.categories[key] = category
            } else {
                s.categories.removeValue(forKey: key)
            }
        }
        onFilterSettingsChanged?()
    }

    func category(of key: String) -> Category? { settings.category(of: key) }

    /// Effective category — what actually colours the tiles. UI reads this so
    /// an unclassified row shows its default (harmful) as selected.
    func effectiveCategory(of key: String) -> Category { settings.effectiveCategory(of: key) }

    /// Toggling the default changes where unclassified time is scored, so it
    /// needs a re-aggregation, same as a filter or category edit.
    func setUnclassifiedHarmful(_ on: Bool) {
        mutate { $0.unclassifiedHarmful = on }
        onFilterSettingsChanged?()
    }

    /// The weight only re-weighs the score at render, so it does NOT need a
    /// re-aggregation — the `$settings` sink already re-pushes it to the widget.
    func setHarmfulWeight(_ weight: Double) {
        mutate { $0.harmfulWeight = weight }
    }

    func setAccentBad(_ hex: String) {
        mutate { $0.accentBad = hex }
    }

    func setAppearance(_ appearance: Appearance) {
        mutate { $0.appearance = appearance }
    }

    func setLiquidGlass(_ on: Bool) {
        mutate { $0.liquidGlass = on }
    }

    func setLanguage(_ language: Language) {
        mutate { $0.language = language }
    }

    func setShowLegend(_ on: Bool) {
        mutate { $0.showLegend = on }
    }

    // MARK: - Apps & sites

    private func list(for kind: FilterKind) -> FilterLists {
        kind == .app ? settings.apps : settings.sites
    }

    func isTracked(_ key: String, kind: FilterKind) -> Bool {
        settings.keeps(key, in: list(for: kind))
    }

    /// Flips whether `key` is counted, regardless of whether the active
    /// `mode` is `.allow` or `.deny` – the UI only ever shows a single
    /// on/off switch per row (per the mockup), so this is the piece that
    /// translates "user wants this off" into "append to deny" (deny
    /// mode) or "remove from allow" (allow mode), and the mirror for on.
    func setTracked(_ key: String, kind: FilterKind, on: Bool) {
        mutate { s in
            switch kind {
            case .app: SettingsStore.applyToggle(&s.apps, mode: s.mode, key: key, on: on)
            case .site: SettingsStore.applyToggle(&s.sites, mode: s.mode, key: key, on: on)
            }
        }
        onFilterSettingsChanged?()
    }

    /// Note on the `allow` array under `.deny` mode (and symmetrically
    /// `deny` under `.allow` mode): `Settings.keeps()` – ported straight
    /// from `aggregate.py` – only ever consults `deny` in deny mode and
    /// only ever consults `allow` in allow mode, so the *other* array is
    /// functionally inert for filtering. This method still records a
    /// "turned on" key there when it isn't already denied, purely so
    /// `candidates(kind:)` (and thus the settings list) has *something*
    /// on disk to recover the key from later – otherwise "turn an
    /// already-implicitly-tracked item on" (a no-op for filtering) would
    /// silently vanish the row from the UI it was just toggled in. This
    /// does not change `Settings`' on-disk shape (still just the two
    /// arrays from ARCHITECTURE.md) or aggregation behaviour, only which of
    /// the two arrays a "yes, keep this" ends up recorded in.
    private static func applyToggle(_ list: inout FilterLists, mode: FilterMode, key: String, on: Bool) {
        switch mode {
        case .deny:
            list.deny.removeAll { $0 == key }
            if on {
                if !list.allow.contains(key) { list.allow.append(key) }
            } else {
                list.deny.append(key)
            }
        case .allow:
            list.allow.removeAll { $0 == key }
            if on {
                list.allow.append(key)
            } else if !list.deny.contains(key) {
                list.deny.append(key)
            }
        }
    }

    /// "Добавить вручную": a key the user typed that isn't in any list
    /// yet. Added as tracked (on) – matches the mockup's "+ Добавить
    /// вручную" existing only to *add* coverage, not to pre-emptively
    /// exclude something.
    func addManual(_ rawKey: String, kind: FilterKind) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        setTracked(key, kind: kind, on: true)
    }

    func setDisplayName(_ name: String, for key: String) {
        mutate { $0.names[key] = name }
    }

    /// Rows to show in the "Приложения и сайты" screen: everything already
    /// named in `apps.allow`/`apps.deny` (resp. `sites.*`) plus every
    /// identifier the data-layer catalog (Data/Catalog.swift) has ever
    /// recorded for this `kind`.
    ///
    /// Fixed from the stage-4 known limitation (see history/STAGE4.md / ARCHITECTURE.md
    /// "Каталог идентификаторов"): the accumulated `activity.json` history
    /// only ever stored post-aggregation *display* names ("Claude", "VLC"),
    /// never the underlying bundle id / domain, so candidates used to be
    /// recovered only for entries that happened to already have a `names`
    /// override, classified by a string-shape heuristic
    /// (`SettingsStore.classify`, kept below only as a fallback for manual
    /// adds with no catalog entry – no longer used on this path). The
    /// aggregator now writes `catalog.json` with the raw id and its real
    /// `kind` straight from the stream (`/app/usage` vs `/app/webUsage`),
    /// so this reads that instead of guessing.
    func candidates(kind: FilterKind) -> [FilterCandidate] {
        let own = list(for: kind)
        var keys = Set(own.allow).union(own.deny)
        let catalogKind: CatalogKind = kind == .app ? .app : .site
        for entry in catalog.loadPrevious().values where entry.kind == catalogKind {
            keys.insert(entry.id)
        }
        return keys.sorted().map { key in
            FilterCandidate(
                key: key,
                kind: kind,
                displayName: Aggregator.displayName(key, isWeb: kind == .site, overrides: settings.names)
            )
        }
    }

    /// Every candidate, apps and sites together, for the category-grouped
    /// view. Sorted by display name so a group reads like a list of apps
    /// rather than a list of reverse-DNS identifiers.
    func allCandidates() -> [FilterCandidate] {
        (candidates(kind: .app) + candidates(kind: .site))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Candidates carrying a given classification (`nil` = neutral).
    func candidates(category: Category?) -> [FilterCandidate] {
        allCandidates().filter { settings.category(of: $0.key) == category }
    }

    /// Best-effort app-vs-site guess for a bare key with no catalog entry
    /// and no explicit allow/deny entry – e.g. a manually-added key typed
    /// before the catalog ever saw it. Reverse-DNS bundle ids
    /// conventionally *start* with a generic segment ("com.apple.Terminal",
    /// "ru.keepcoder.Telegram"); domains conventionally *end* with one
    /// ("github.com", "aliexpress.ru"). Ambiguous two-segment values
    /// default to `.app`. Not authoritative, and **not used by
    /// `candidates(kind:)`** (which now reads real kinds from the
    /// catalog) – this only exists as a fallback the UI could use for
    /// "Добавить вручную" if it ever needs to guess a kind instead of
    /// asking the user directly (currently it doesn't: the popover has an
    /// explicit Приложение/Сайт picker).
    static func classify(_ key: String) -> FilterKind {
        let segments = key.split(separator: ".").map(String.init)
        guard segments.count >= 2 else { return .app }
        let tldish: Set<String> = ["com", "org", "net", "ru", "md", "edu", "gov", "io", "de", "fr", "uk", "app"]
        if segments.count >= 3, tldish.contains(segments[0]) { return .app }
        if let last = segments.last, tldish.contains(last) { return .site }
        return .app
    }
}
