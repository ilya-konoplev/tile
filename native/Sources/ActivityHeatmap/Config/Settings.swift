import AppKit
import Foundation

/// Settings model – format documented in ARCHITECTURE.md, "Настройки".
/// Read and written through `SettingsStore`, which owns persistence and is
/// the single source of truth for both the settings window and the menu bar.
struct FilterLists: Codable, Equatable {
    var allow: [String] = []
    var deny: [String] = []
}

enum FilterMode: String, Codable {
    case deny
    case allow
}

/// Window appearance. `system` is kept alongside the handoff's two options on
/// purpose: HIG asks apps to respect the system setting, and the app followed it
/// until now — dropping it in a pass whose whole point is HIG compliance would
/// be a regression. It is the default, so nothing changes unless asked.
enum Appearance: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// How an app or site affects the day's balance. Absence from
/// `Settings.categories` means *neutral*: the time is still counted in the
/// day's total, it just does not push the balance either way.
///
/// Neutral is the default on purpose – a real catalog runs to a couple of
/// hundred identifiers and nobody is going to classify them all up front,
/// so an unclassified app must not silently be treated as either good or bad.
enum Category: String, Codable, CaseIterable {
    case useful
    case neutral
    case destructive

    var sign: Int {
        switch self {
        case .useful: return 1
        case .neutral: return 0
        case .destructive: return -1
        }
    }
}

struct Settings: Codable, Equatable {
    var widgetEnabled: Bool = true
    var launchAtLogin: Bool = false
    var mode: FilterMode = .deny
    var apps: FilterLists = FilterLists()
    var sites: FilterLists = FilterLists()
    var names: [String: String] = [:]
    /// identifier (bundle id / domain) -> category. An ABSENT key means "the
    /// user has not classified this yet" — its effective category is then
    /// decided by `unclassifiedHarmful` (see `effectiveCategory`). An explicit
    /// `.neutral` is different: it means "the user chose to exclude this from
    /// the balance", and always wins over the default.
    var categories: [String: Category] = [:]
    /// Treat anything the user has not classified as harmful. Requested as the
    /// default: "виновен, пока не доказал пользу". Everything the mac actually
    /// spent time on drags the balance down until marked useful (or neutral).
    /// A setting, not a hardcoded rule, so it stays reversible without touching
    /// per-item categories.
    var unclassifiedHarmful: Bool = true
    /// How heavily harmful time weighs against useful time in the balance.
    /// 1.0 is the honest 1:1 the app shipped with; raising it makes an hour
    /// wasted cost more than an hour earned. Applied only to the *score* (tile
    /// colour and the balance figure); the tooltip's +/− breakdown stays real
    /// time. Clamped to a sane band on read.
    var harmfulWeight: Double = 1.0
    var accent: String = "#9974f7"
    /// Accent for negative-balance days. Defaults to the design's own negative
    /// orange, so the two ramps read as one palette rather than a generic red
    /// bolted on.
    var accentBad: String = "#e07a3f"
    /// The pre-design default for `accentBad`. It was never offered as a
    /// swatch, so any settings.json still holding it got it from us, not from
    /// the user – see `init(from:)`.
    static let legacyAccentBad = "#f7a05f"
    var showLegend: Bool = true
    var cellSize: Int = 22
    var language: Language = .system
    /// "Liquid glass": saturated backdrop plus the lit rims on the card and on
    /// every tile, as in the designer's original. Off gives the flatter,
    /// quieter card.
    var liquidGlass: Bool = true
    /// Light/dark override. `system` follows macOS, which is what the app did
    /// unconditionally until the HIG pass — the handoff now puts an explicit
    /// «Оформление» segment in the settings window.
    var appearance: Appearance = .system
    /// Proportional scale of the whole widget. The design is one fixed
    /// layout (a 660pt-wide card), so the card is never resized along one
    /// axis – width and height always move together.
    var scale: Double = 1.0
    var minSeconds: Int = 60

    init() {}

    /// Tolerant decoding: every field falls back to its default when the key
    /// is absent.
    ///
    /// This is not cosmetic. Swift's synthesised `Codable` does NOT apply
    /// property defaults for missing keys – it throws `keyNotFound`. Combined
    /// with `load()`'s "defaults on any failure" fallback, adding a single new
    /// field would make every existing settings.json fail to decode and
    /// silently reset the user's filters, accent and scale. That happened when
    /// `language` was added; verified against a real file before this fix.
    /// Any field added later must be read the same way.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        widgetEnabled = try c.decodeIfPresent(Bool.self, forKey: .widgetEnabled) ?? d.widgetEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        mode = try c.decodeIfPresent(FilterMode.self, forKey: .mode) ?? d.mode
        apps = try c.decodeIfPresent(FilterLists.self, forKey: .apps) ?? d.apps
        sites = try c.decodeIfPresent(FilterLists.self, forKey: .sites) ?? d.sites
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? d.names
        categories = try c.decodeIfPresent([String: Category].self, forKey: .categories) ?? d.categories
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? d.accent
        // `#f7a05f` was our own default before the design shipped its negative
        // scale, and it was never one of the offered swatches – so a file
        // holding it records what we wrote, not a choice the user made.
        // Carrying it forward would leave those users on a generated OKLCH ramp
        // that matches no preset in the settings window. Migrate it instead.
        let storedBad = try c.decodeIfPresent(String.self, forKey: .accentBad) ?? d.accentBad
        accentBad = storedBad.caseInsensitiveCompare(Settings.legacyAccentBad) == .orderedSame
            ? d.accentBad
            : storedBad
        showLegend = try c.decodeIfPresent(Bool.self, forKey: .showLegend) ?? d.showLegend
        cellSize = try c.decodeIfPresent(Int.self, forKey: .cellSize) ?? d.cellSize
        language = try c.decodeIfPresent(Language.self, forKey: .language) ?? d.language
        liquidGlass = try c.decodeIfPresent(Bool.self, forKey: .liquidGlass) ?? d.liquidGlass
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        unclassifiedHarmful = try c.decodeIfPresent(Bool.self, forKey: .unclassifiedHarmful) ?? d.unclassifiedHarmful
        harmfulWeight = try c.decodeIfPresent(Double.self, forKey: .harmfulWeight) ?? d.harmfulWeight
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        minSeconds = try c.decodeIfPresent(Int.self, forKey: .minSeconds) ?? d.minSeconds
    }

    /// The *explicitly stored* category, or nil if the user has not classified
    /// this key. Use this only where the distinction "set vs untouched" matters
    /// (it no longer does anywhere in practice); scoring and display want
    /// `effectiveCategory`.
    func category(of key: String) -> Category? { categories[key] }

    /// The category actually used for scoring and colour: the explicit one if
    /// set, otherwise the default — harmful when `unclassifiedHarmful` is on,
    /// neutral otherwise. Never nil, so callers handle three concrete cases.
    func effectiveCategory(of key: String) -> Category {
        categories[key] ?? (unclassifiedHarmful ? .destructive : .neutral)
    }

    /// Harmful weight clamped to a usable band. 1.0 is honest 1:1; the cap
    /// keeps a hand-edited settings.json from producing a balance no positive
    /// day could ever offset.
    var clampedHarmfulWeight: Double { min(max(harmfulWeight, 1.0), 5.0) }

    /// Signed contribution of `seconds` spent on `key`, using the effective
    /// category and the harmful weight. Harmful time is scaled; useful is 1:1.
    func signedContribution(_ seconds: Double, for key: String) -> Double {
        let category = effectiveCategory(of: key)
        let magnitude = category == .destructive ? clampedHarmfulWeight : 1.0
        return seconds * Double(category.sign) * magnitude
    }

    /// Whether `value` passes the allow/deny filter for the given list –
    /// port of `keeps()` in aggregate.py.
    func keeps(_ value: String, in list: FilterLists) -> Bool {
        switch mode {
        case .allow: return list.allow.contains(value)
        case .deny: return !list.deny.contains(value)
        }
    }

    /// `~/Library/Application Support/ActivityHeatmap/settings.json`
    static var defaultURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ActivityHeatmap/settings.json")
    }

    /// Defaults (`Settings()`) on any read/decode failure: a missing file
    /// just means "nobody has customised anything", not an error. Note that
    /// this fallback is exactly why `init(from:)` above must tolerate missing
    /// keys – otherwise one new field would silently reset everything.
    static func load(url: URL = defaultURL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }
}
