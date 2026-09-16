import AppKit
import SwiftUI

/// Light/dark theming, from the handoff's "Dark Theme" section.
///
/// Two facts from that section shape everything here:
///
///   - the theme follows the system (`@Environment(\.colorScheme)` in the
///     handoff's words), so there is no setting to add and nothing to persist;
///   - the accent and **every tile/category colour scale are identical in both
///     themes**. Only glass, background and ink change. So `Palette` is not
///     touched by any of this – a purple day is the same purple at midnight.
///
/// The mechanism is a dynamic `NSColor` rather than `@Environment(\.colorScheme)`
/// plumbing. AppKit resolves such a colour against whatever appearance is
/// drawing it, which means every existing `SettingsTokens.ink90`-style call
/// site keeps working untouched, the tokens stay `static let`s, and no view has
/// to learn which theme it is in. Threading an environment value through
/// instead would have rewritten several hundred call sites across three
/// surfaces to express exactly the same thing.
extension Color {
    static func themed(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }

    /// Convenience for the common "white veil at different strengths" pattern
    /// that the dark theme uses everywhere in place of dark ink.
    static func themedWhite(light: Double, dark: Double) -> Color {
        .themed(light: .white.opacity(light), dark: .white.opacity(dark))
    }
}

/// The two ink bases. Opacity is applied by the callers, exactly as the
/// mockups apply alpha to `rgba(...)`.
enum KiInk {
    /// Light ink for every surface: `rgb(30,25,50)`, the app-wide value from
    /// the designer's `KiTheme.swift`.
    static let light = Color(red: 30 / 255, green: 25 / 255, blue: 50 / 255)

    /// Windows: `rgba(240,237,250,α)`.
    static let window = Color.themed(light: light, dark: Color(red: 240 / 255, green: 237 / 255, blue: 250 / 255))

    /// The widget carries its own, marginally cooler dark ink –
    /// `rgba(238,240,250,α)` in the handoff. Two hex digits apart from
    /// `window`, and called out separately there, so it is kept separate here.
    static let widget = Color.themed(light: light, dark: Color(red: 238 / 255, green: 240 / 255, blue: 250 / 255))
}

/// Glass, shared by the settings window, the tray panel and the widget card.
///
/// The dark numbers are the handoff's; the light ones are what is already on
/// screen and confirmed by user screenshots, which in two places is
/// deliberately *thinner* than the mockup. The reason is the same in both
/// themes and worth stating once: in the mockup the glass sits on a lavender
/// page that shows through it, whereas here it sits on the user's wallpaper
/// behind a real `NSVisualEffectView` blur. The mockup's white has to
/// compensate for a `backdrop-filter` that blurs nothing in a transparent
/// window; ours does not.
/// The handoff's optional "Glass Version" – `liquidGlass` in Settings.
///
/// Its own words: *«та же логика и токены, отличается только материалом»*. The
/// settings mockups bear that out exactly – ink, dividers, field fills, chips
/// and the segment control are byte-identical between the two files. Only four
/// things change: the glass fill (which grows a third, faintly purple stop),
/// the rim, the shadow, and how transparent nested cards are.
///
/// So this is a *material*, not a theme: it multiplies with light/dark rather
/// than replacing it, and every value below exists in four variants.
struct KiGlassStyle {
    /// `Settings.liquidGlass`, unless overridden for diagnostics. The handoff
    /// now calls this a *material* with two named values — «Обычный» (regular)
    /// and «Liquid Glass» — and puts a segmented control for it in the settings
    /// window. The stored field stays a `Bool` on purpose: it already holds
    /// exactly this two-valued choice, and changing the type would break every
    /// existing settings.json for no gain.
    var intense: Bool = true

    init(intense: Bool = true) {
        self.intense = KiDiagnostics.forcedGlass ?? intense
    }

    // MARK: Window / card surface

    /// Regular is genuinely **opaque** — `backdrop-filter: none` in the mockup,
    /// solid `#ececec` / `#252527`. That is the whole point of the variant: it
    /// is the fallback that stays legible over any wallpaper, and the one to
    /// serve when the system asks for reduced transparency.
    var windowFill: Color {
        Color.themed(light: Color(hex: "#ececec"), dark: Color(hex: "#252527"))
    }

    /// Glass veil over the blur. **This is the transparency knob** — a white
    /// veil at opacity α caps how much backdrop can come through at (1 − α).
    ///
    /// The handoff's own light values are .66 → .38; ours are thinner because
    /// the mockup's `backdrop-filter` blurs nothing in a transparent window and
    /// its white has to stand in for the softness, while `NSVisualEffectView`
    /// really does blur the desktop. Measured: the mockup's numbers capped
    /// transmission at 34 %, close enough to the opaque variant that the
    /// setting barely read as a difference at all.
    var veil: [Color] {
        intense
            ? [Color.themedWhite(light: 0.14, dark: 0.06),
               Color.themedWhite(light: 0.06, dark: 0.02),
               Color.themed(light: Color(hex: "#9974f7").opacity(0.04),
                            dark: Color(hex: "#9974f7").opacity(0.04))]
            : []
    }

    var border: Color {
        intense
            ? Color.themedWhite(light: 0.65, dark: 0.16)
            : Color.themed(light: .black.opacity(0.07), dark: .white.opacity(0.09))
    }

    var borderWidth: CGFloat { intense ? 1.5 : 1 }

    // MARK: Toolbar

    /// Transparent in glass (the window's own material shows through), solid in
    /// regular — `#f6f6f6` / `#2e2e30`, the mockup's stand-in for a vibrancy
    /// toolbar.
    var toolbarFill: Color? {
        intense ? nil : Color.themed(light: Color(hex: "#f6f6f6"), dark: Color(hex: "#2e2e30"))
    }

    var toolbarBorder: Color {
        intense
            ? Color.themedWhite(light: 0.45, dark: 0.10)
            : Color.themed(light: .black.opacity(0.09), dark: .white.opacity(0.08))
    }

    // MARK: Nested cards

    /// Grouped section cards. Regular is solid white / `#2c2c2e`, exactly the
    /// System Settings look the handoff is now asking for.
    var groupFill: Color {
        intense
            ? Color.themedWhite(light: 0.20, dark: 0.035)
            : Color.themed(light: .white, dark: Color(hex: "#2c2c2e"))
    }

    var groupBorder: Color {
        intense
            ? Color.themedWhite(light: 0.70, dark: 0.12)
            : Color.themed(light: .black.opacity(0.06), dark: .white.opacity(0.07))
    }

    /// Fields, off-state tracks, chips, segment tracks.
    var fieldFill: Color {
        intense
            ? Color.themedWhite(light: 0.30, dark: 0.08)
            : Color.themed(light: .black.opacity(0.03), dark: .white.opacity(0.06))
    }

    /// Segment-control track.
    var segmentTrack: Color {
        intense
            ? Color.themedWhite(light: 0.30, dark: 0.12)
            : Color.themed(light: .black.opacity(0.06), dark: .white.opacity(0.12))
    }

    /// The selected segment's raised pill.
    var segmentActive: Color {
        Color.themed(light: .white, dark: .white.opacity(0.16))
    }

    // MARK: Shadows

    /// Glass `0 28px 70px`, regular `0 22px 50px`. Halved for SwiftUI, whose
    /// radius is roughly half the CSS blur.
    var shadowRadius: CGFloat { intense ? 35 : 25 }
    var shadowY: CGFloat { intense ? 28 : 22 }
    var closeShadowRadius: CGFloat { intense ? 4 : 0 }
    var closeShadowY: CGFloat { intense ? 2 : 0 }

    var shadow: Color {
        intense
            ? Color.themed(light: Color(red: 50 / 255, green: 35 / 255, blue: 90 / 255).opacity(0.18),
                           dark: .black.opacity(0.55))
            : Color.themed(light: Color(red: 50 / 255, green: 40 / 255, blue: 85 / 255).opacity(0.22),
                           dark: .black.opacity(0.55))
    }

    var closeShadow: Color {
        Color.themed(light: Color(red: 30 / 255, green: 50 / 255, blue: 60 / 255).opacity(0.08),
                     dark: .black.opacity(0.3))
    }

    /// `inset 0 1.5px 0 rgba(255,255,255,0.95)` – the lit top edge. Glass only:
    /// regular has no inset highlights at all, by design.
    var topGleam: Color? {
        intense ? Color.themedWhite(light: 0.95, dark: 0.28) : nil
    }

    /// `inset 0 0 30px rgba(255,255,255,0.25)` – inner glow. Glass only.
    var bottomReflex: Color { Color.themedWhite(light: 0.25, dark: 0.05) }

    /// Base layer of the selected-swatch ring: it reads as a gap punched out of
    /// the card, so it has to match whatever the card is actually made of.
    /// Regular's card is solid white / `#2c2c2e`; glass's is translucent, where
    /// the handoff asks for `#211d33` on dark.
    var ringBase: Color {
        intense
            ? Color.themed(light: .white, dark: Color(hex: "#211d33"))
            : Color.themed(light: .white, dark: Color(hex: "#2c2c2e"))
    }
}

/// Corner radii, from the handoff's "Радиусы (континуальная кривая)" line.
/// Every one of these dropped in the HIG pass — the window from 26 to 12, the
/// widget card from 34/42 to a single 28 — so they are gathered here rather
/// than left inline, where two of them had already drifted apart.
enum KiRadius {
    static let window: CGFloat = 12
    static let tray: CGFloat = 14
    static let widget: CGFloat = 28
    static let card: CGFloat = 11
    static let iconTile: CGFloat = 7
    static let field: CGFloat = 8
    static let tile: CGFloat = 9
}

/// Diagnostic-only overrides, set from the command line in `main.swift` and
/// never persisted. They live here rather than in `AppDelegate` because the
/// settings window and the tray panel build their own `KiGlassStyle` and would
/// otherwise silently ignore the flag — which they did: an on/off comparison
/// measured byte-identical because only the widget was listening.
enum KiDiagnostics {
    static var forcedGlass: Bool?
}

private struct KiGlassKey: EnvironmentKey {
    static let defaultValue = KiGlassStyle()
}

extension EnvironmentValues {
    /// Set once at each surface's root from `Settings.liquidGlass`.
    var kiGlass: KiGlassStyle {
        get { self[KiGlassKey.self] }
        set { self[KiGlassKey.self] = newValue }
    }
}

enum KiGlass {
    /// Card/window veil over the blur. Dark: `rgba(255,255,255,0.10)` →
    /// `0.04`.
    static let veilTop = Color.themedWhite(light: 0.52, dark: 0.10)
    static let veilBottom = Color.themedWhite(light: 0.30, dark: 0.04)

    /// Rim. Dark: `rgba(255,255,255,0.12)`.
    static let border = Color.themedWhite(light: 0.60, dark: 0.12)
    /// Lit top edge of the rim (`inset 0 1px 0 rgba(255,255,255,0.16)` dark).
    static let borderLit = Color.themedWhite(light: 0.85, dark: 0.16)
    static let borderShade = Color.themedWhite(light: 0.35, dark: 0.06)

    /// Nested groups: rows, cards inside cards. Dark: fill
    /// `rgba(255,255,255,0.06)`, border `rgba(255,255,255,0.1)`.
    static let groupFill = Color.themedWhite(light: 0.50, dark: 0.06)
    static let groupBorder = Color.themedWhite(light: 0.65, dark: 0.10)

    /// Inputs, chips, segment controls. Dark sits in the handoff's
    /// `rgba(255,255,255,0.08–0.18)` band for interactive fills.
    static let fieldFill = Color.themedWhite(light: 0.55, dark: 0.08)
    static let fieldBorder = Color.themedWhite(light: 0.70, dark: 0.12)

    /// Drop shadow. Dark: `0 24px 60px rgba(0,0,0,0.45)`.
    static let shadow = Color.themed(
        light: Color(red: 0x32 / 255, green: 0x23 / 255, blue: 0x5A / 255).opacity(0.16),
        dark: .black.opacity(0.45)
    )

    /// Base layer of the selected-swatch ring – `#fff` on light, `#211d33` on
    /// dark, so the ring reads as a gap punched out of the surface either way.
    static let ringBase = Color.themed(light: .white, dark: Color(red: 0x21 / 255, green: 0x1D / 255, blue: 0x33 / 255))
}
