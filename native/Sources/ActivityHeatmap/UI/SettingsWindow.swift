import AppKit
import Combine
import SQLite3
import SwiftUI

/// The settings window, built from the design handoff's `Ki App Settings.dc.html`
/// – screen 1 "ГЛАВНОЕ ОКНО" and screen 2 "ПРИЛОЖЕНИЯ И САЙТЫ". Screen 3 of that
/// file is the tray panel and lives in `TrayPanel.swift`.
///
/// Unlike `DesktopWindow.swift` this is an ordinary framed `NSWindow`, not a
/// desktop-level borderless one – none of the risk list in ARCHITECTURE.md
/// ("уровень desktopIconWindow + 1", `acceptsMouseMovedEvents`,
/// `sizingOptions = []`) applies here, and this file must not touch
/// `DesktopWindow.swift`/`HeatmapView.swift`.

// MARK: - Full Disk Access status

/// Determines FDA by *actually trying* to open `knowledgeC.db` read-only
/// and run a trivial query against it – per the stage-4 brief, not by
/// guessing from `FileManager.fileExists` (TCC can make a protected path
/// simply not exist as far as `stat` is concerned, which is indistinguishable
/// from a missing file that way). Without Full Disk Access this reliably
/// surfaces as `SQLITE_AUTH` (code 23) on this machine – confirmed live
/// while building this file – but the check treats *any* non-`SQLITE_OK`/
/// `SQLITE_ROW`/`SQLITE_DONE` outcome as "no access" rather than pattern
/// matching a specific code, since the exact failure mode (CANTOPEN vs.
/// AUTH vs. NOTADB) has been observed to vary by macOS version in prior
/// stages' notes.
enum FullDiskAccess {
    enum Status: Equatable {
        case granted
        case denied
    }

    static func check(dbPath: String = Knowledge.defaultDBPath) -> Status {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard openRC == SQLITE_OK, let db else { return .denied }

        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(db, "SELECT 1 FROM ZOBJECT LIMIT 1", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard prepareRC == SQLITE_OK else { return .denied }

        let stepRC = sqlite3_step(stmt)
        return (stepRC == SQLITE_ROW || stepRC == SQLITE_DONE) ? .granted : .denied
    }

    /// Opens System Settings' Full Disk Access pane. This only *opens*
    /// the panel – it cannot and does not grant anything; the user has to
    /// flip the switch themselves and relaunch the app.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Design tokens

/// Verbatim from the handoff's "Design Tokens" section. Ink is
/// `rgba(30,25,50,α)`; every opacity below appears in the mockup as written.
enum SettingsTokens {
    /// Light `rgba(30,25,50,α)`, dark `rgba(240,237,250,α)`.
    ///
    /// Flipping the base is enough for almost every token below, and that is
    /// not luck – the handoff's dark values for the surfaces these alphas draw
    /// (separators `rgba(255,255,255,0.06–0.08)`, off-state toggles and field
    /// fills `rgba(255,255,255,0.08–0.18)`) are the same alphas over white that
    /// the light theme uses over ink. Where the dark theme genuinely departs
    /// from that – glass, groups, rings – the token is themed explicitly.
    static func ink(_ alpha: Double) -> Color {
        KiInk.window.opacity(alpha)
    }

    static let ink90 = ink(0.9)
    static let ink85 = ink(0.85)
    static let ink75 = ink(0.75)
    static let ink65 = ink(0.65)
    static let ink55 = ink(0.55)
    static let ink50 = ink(0.5)
    static let ink45 = ink(0.45)
    static let ink40 = ink(0.4)
    static let ink35 = ink(0.35)
    static let ink15 = ink(0.15)
    static let ink12 = ink(0.12)
    static let ink07 = ink(0.07)
    static let ink06 = ink(0.06)
    static let ink05 = ink(0.05)

    static let accent = Color(hex: "#9974f7")
    static let accentHover = Color(hex: "#7d55e0")
    /// Negative/harmful. The design's own orange – the same hue the negative
    /// tile ramp is built from, so the settings row and the tiles it controls
    /// are visibly one thing.
    static let bad = Color(hex: "#e07a3f")
    static let mint = Color(hex: "#4fc9a8")
    /// The Full Disk Access warning is a *softer* orange than the harmful
    /// category – it is a status, not a classification.
    static let warn = Color(hex: "#f7a05f")

    // Surface colours deliberately do NOT live here. They depend on the
    // *material* (regular vs Liquid Glass), which a `static let` cannot see —
    // that is exactly how the Apps & Sites screen ended up ignoring the
    // material switch while the main screen honoured it. Read them from
    // `@Environment(\.kiGlass)` instead.

    static let avatarPalette = ["#9974f7", "#5f9df7", "#4fc9a8", "#f7a05f", "#f772c9"]

    /// Stable per-identifier avatar tint. `hashValue` is seeded per process on
    /// Swift, so the same app would change colour between launches – hash the
    /// bytes ourselves instead, which the mockup's fixed per-app colours imply.
    static func avatarColor(for key: String) -> Color {
        var h: UInt64 = 5381
        for byte in key.utf8 { h = (h &* 33) &+ UInt64(byte) }
        return Color(hex: avatarPalette[Int(h % UInt64(avatarPalette.count))])
    }
}

// MARK: - Shared chrome

/// The mockup's nested glass group: `rgba(255,255,255,0.5)`, 1px
/// `rgba(255,255,255,0.65)` border, radius 16, top inset highlight.
private struct GlassGroup<Content: View>: View {
    var padding: EdgeInsets? = nil
    @ViewBuilder var content: Content
    /// Nested cards are markedly more transparent in the glass version –
    /// light 0.30 against 0.50 – which is most of what makes that variant
    /// read as glass rather than as a lighter panel.
    @Environment(\.kiGlass) private var glass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding ?? EdgeInsets())
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(glass.groupFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(glass.groupBorder, lineWidth: 1)
                    )
            )
    }
}

/// Hairline between rows inside a group. The handoff insets it by 54pt so it
/// starts under the text column, not under the icon — the iOS/macOS Settings
/// convention.
private struct RowDivider: View {
    var inset: CGFloat = 54
    var body: some View {
        Rectangle()
            .fill(SettingsTokens.ink07)
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

/// The mockup's switch: 44×26 track, 22px white knob, 0.18s. The system
/// `Toggle` renders as the platform's blue/green switch, which is not this.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var width: CGFloat = 44
    var height: CGFloat = 26

    var body: some View {
        let knob = height - 4
        Capsule()
            .fill(isOn ? SettingsTokens.accent : SettingsTokens.ink15)
            .frame(width: width, height: height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: SettingsTokens.ink(0.25), radius: 3, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
            .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

/// Title + subtitle stack used by every row in the mockup: 14/600 over 12/500.
private struct RowLabel: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // HIG pass: 13/500 over 11.5, down from 14/600 over 12. System
            // Settings rows are quieter than the old mockup's.
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTokens.ink90)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTokens.ink50)
            }
        }
    }
}

/// The coloured 28pt tile that now opens every settings row, as in System
/// Settings. `Image(systemName:)` rather than hand-drawn vectors: the handoff
/// draws SVGs only because HTML has no SF Symbols, and names the real symbol
/// for each row in its own table.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: KiRadius.iconTile, style: .continuous)
            .fill(tint)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: KiRadius.iconTile, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
            )
            .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
    }
}

/// Symbol + tint per row, from the handoff's own table. Kept together so the
/// pairing is checkable at a glance rather than scattered down the file.
enum SettingsRowIcon {
    static let appearance = (symbol: "circle.lefthalf.filled", tint: Color(hex: "#5e5ce6"))
    static let material = (symbol: "sparkles", tint: Color(hex: "#9974f7"))
    static let widgetOn = (symbol: "square.grid.2x2", tint: Color(hex: "#30d158"))
    static let launch = (symbol: "power", tint: Color(hex: "#ff9f0a"))
    static let scale = (symbol: "arrow.up.left.and.arrow.down.right", tint: Color(hex: "#8e8e93"))
    static let good = (symbol: "drop.fill", tint: Color(hex: "#9974f7"))
    static let bad = (symbol: "drop.fill", tint: Color(hex: "#e07a3f"))
    static let apps = (symbol: "globe", tint: Color(hex: "#0a84ff"))
    static let legend = (symbol: "list.bullet", tint: Color(hex: "#8e8e93"))
    static let language = (symbol: "character.bubble", tint: Color(hex: "#5e5ce6"))
    static let defaultHarmful = (symbol: "exclamationmark.shield", tint: Color(hex: "#e07a3f"))
    static let weight = (symbol: "scalemass", tint: Color(hex: "#e07a3f"))
}

/// A titled group of rows — the System Settings section. The header is
/// sentence-case 12/600 in the secondary ink, sitting outside the card.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTokens.ink50)
                .padding(.horizontal, 6)
            GlassGroup { content }
        }
    }
}

/// One row: icon tile, text column, trailing control.
struct SettingsRow<Trailing: View>: View {
    let icon: (symbol: String, tint: Color)
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: icon.symbol, tint: icon.tint)
            RowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// Segment control in the System Settings idiom: a pill track with the active
/// option raised on its own light pill. Used for appearance and material.
struct SettingsSegment<Value: Hashable>: View {
    let options: [(value: Value, label: String, symbol: String?)]
    @Binding var selection: Value
    @Environment(\.kiGlass) private var glass

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { option in
                let active = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                        }
                        Text(option.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(active ? SettingsTokens.ink90 : SettingsTokens.ink40)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(active ? glass.segmentActive : .clear)
                            .shadow(color: active ? .black.opacity(0.16) : .clear, radius: 1.5, y: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .fixedSize()
        .background(Capsule().fill(glass.segmentTrack))
        .animation(.easeInOut(duration: 0.18), value: selection)
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 16)
            SettingsSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}

/// A 26px colour swatch. Selected state is the mockup's double ring –
/// `0 0 0 2px #fff, 0 0 0 4px <colour>` – drawn as two concentric strokes
/// outside the circle, which is why the row reserves 4pt of slack around it.
private struct ColorSwatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void
    /// The ring's base layer punches a hole in whatever the card is made of,
    /// so it has to know the material.
    @Environment(\.kiGlass) private var glass

    var body: some View {
        let colour = Color(hex: hex)
        Button(action: action) {
            Circle()
                .fill(colour)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle().strokeBorder(Color.themedWhite(light: 0.5, dark: 0.14), lineWidth: isSelected ? 0 : 1)
                )
                // Inner ring of `0 0 0 2px #fff, 0 0 0 4px <colour>`. On dark
                // the handoff swaps that white base for `#211d33`, so the ring
                // still reads as a gap punched out of the surface rather than
                // a bright halo.
                .overlay(
                    Circle().stroke(glass.ringBase, lineWidth: 2).padding(-1)
                        .opacity(isSelected ? 1 : 0)
                )
                .overlay(
                    Circle().stroke(colour, lineWidth: 2).padding(-3)
                        .opacity(isSelected ? 1 : 0)
                )
                .padding(4)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

/// Row that highlights under the pointer, as the mockup's navigation and menu
/// rows do. Plain `.onHover` on a container, kept in one place so every
/// hoverable surface uses the same 0.15s and the same shape.
private struct HoverRow<Content: View>: View {
    var highlight: Color
    var radius: CGFloat = 16
    var action: () -> Void
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? highlight : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Screen 1 · Главное окно

struct MainSettingsView: View {
    @ObservedObject var store: SettingsStore
    let onOpenAppsSites: () -> Void

    private var s: L10n { L10n(store.settings.language) }
    @State private var access: FullDiskAccess.Status = FullDiskAccess.check()
    @State private var launchAtLoginError: String?

    var body: some View {
        ScrollView {
            // Four titled sections, in the handoff's order. Gap 22 between
            // sections, window padding 20/18 — both from its layout note.
            VStack(alignment: .leading, spacing: 22) {
                appearanceSection
                widgetSection
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTokens.bad)
                        .padding(.horizontal, 6)
                }
                tilesSection
                dataSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .onAppear { access = FullDiskAccess.check() }
        // Re-check whenever the window becomes key again – the natural moment a
        // user comes back after granting access in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            access = FullDiskAccess.check()
        }
    }

    /// «Внешний вид» — the two segmented controls the HIG pass introduced,
    /// plus language (ours, not in the handoff, but it belongs in this group).
    private var appearanceSection: some View {
        SettingsSection(title: s.sectionAppearance) {
            SettingsRow(icon: SettingsRowIcon.appearance,
                        title: s.appearanceRow, subtitle: s.appearanceHint) {
                SettingsSegment(
                    options: [
                        // Text only: with three options the icons pushed the
                        // row past the window's 456pt and SwiftUI broke the
                        // labels one character per line.
                        (Appearance.system, s.appearanceSystem, nil),
                        (Appearance.light, s.appearanceLight, nil),
                        (Appearance.dark, s.appearanceDark, nil),
                    ],
                    selection: Binding(
                        get: { store.settings.appearance },
                        set: { store.setAppearance($0) }
                    )
                )
            }
            RowDivider()
            SettingsRow(icon: SettingsRowIcon.material,
                        title: s.materialRow, subtitle: s.materialHint) {
                SettingsSegment(
                    options: [
                        (false, s.materialRegular, nil),
                        (true, s.materialGlass, "sparkles"),
                    ],
                    selection: Binding(
                        get: { store.settings.liquidGlass },
                        set: { store.setLiquidGlass($0) }
                    )
                )
            }
            RowDivider()
            SettingsRow(icon: SettingsRowIcon.language, title: s.language) {
                Picker("", selection: Binding(
                    get: { store.settings.language },
                    set: { store.setLanguage($0) }
                )) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName(s)).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    /// «Виджет» — the two switches, the scale slider and the legend toggle.
    private var widgetSection: some View {
        SettingsSection(title: s.sectionWidget) {
            SettingsRow(icon: SettingsRowIcon.widgetOn,
                        title: s.widgetEnabled, subtitle: s.widgetEnabledHint) {
                SettingsSwitch(isOn: Binding(
                    get: { store.settings.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }
                ))
            }
            RowDivider()
            SettingsRow(icon: SettingsRowIcon.launch,
                        title: s.launchAtLogin, subtitle: s.launchAtLoginHint) {
                SettingsSwitch(isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { on in
                        if let error = store.setLaunchAtLogin(on) {
                            launchAtLoginError = s.launchAtLoginFailed(error.localizedDescription)
                        } else {
                            launchAtLoginError = nil
                        }
                    }
                ))
            }
            RowDivider()
            // The slider runs full width *under* its row, as the handoff draws
            // it — a 60–140 % range needs more room than a trailing control.
            VStack(alignment: .leading, spacing: 4) {
                SettingsRow(icon: SettingsRowIcon.scale,
                            title: s.widgetScale, subtitle: s.widgetScaleHint) {
                    Text("\(Int((store.settings.scale * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SettingsTokens.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(SettingsTokens.accent.opacity(0.12)))
                }
                scaleControl
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            RowDivider()
            SettingsRow(icon: SettingsRowIcon.legend, title: s.showLegend) {
                SettingsSwitch(isOn: Binding(
                    get: { store.settings.showLegend },
                    set: { store.setShowLegend($0) }
                ))
            }
        }
    }

    /// «Плитки активности» — the two colour scales.
    private var tilesSection: some View {
        SettingsSection(title: s.sectionTiles) {
            SettingsRow(icon: SettingsRowIcon.good, title: s.accentColor, subtitle: s.accentHint) {
                swatchStrip(options: Palette.presets.map(\.hex),
                            selected: store.settings.accent,
                            select: { store.setAccent($0) })
            }
            RowDivider()
            SettingsRow(icon: SettingsRowIcon.bad, title: s.accentColorBad) {
                swatchStrip(options: Palette.badPresets.map(\.hex),
                            selected: store.settings.accentBad,
                            select: { store.setAccentBad($0) })
            }
            RowDivider()
            SettingsRow(icon: SettingsRowIcon.defaultHarmful,
                        title: s.unclassifiedHarmful, subtitle: s.unclassifiedHarmfulHint) {
                SettingsSwitch(isOn: Binding(
                    get: { store.settings.unclassifiedHarmful },
                    set: { store.setUnclassifiedHarmful($0) }
                ))
            }
            RowDivider()
            // Weight runs full width under its row, like the widget-scale slider.
            VStack(alignment: .leading, spacing: 4) {
                SettingsRow(icon: SettingsRowIcon.weight,
                            title: s.harmfulWeightRow, subtitle: s.harmfulWeightHint) {
                    Text(String(format: "%.1f×", store.settings.clampedHarmfulWeight))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SettingsTokens.bad)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(SettingsTokens.bad.opacity(0.14)))
                }
                Slider(
                    value: Binding(
                        get: { store.settings.clampedHarmfulWeight },
                        set: { store.setHarmfulWeight($0) }
                    ),
                    in: 1.0...5.0
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }

    /// «Данные» — the apps/sites push row and the Full Disk Access card.
    private var dataSection: some View {
        let all = store.allCandidates()
        let tracked = all.filter { store.isTracked($0.key, kind: $0.kind) }.count
        return SettingsSection(title: s.sectionData) {
            HoverRow(highlight: SettingsTokens.accent.opacity(0.12), action: onOpenAppsSites) {
                SettingsRow(icon: SettingsRowIcon.apps,
                            title: s.appsSitesTitle,
                            subtitle: s.trackedSummary(tracked, of: all.count)) {
                    Text("\u{203A}")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SettingsTokens.ink35)
                }
            }
            RowDivider()
            accessCard.padding(12)
        }
    }

    private func swatchStrip(options: [String], selected: String, select: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { hex in
                ColorSwatch(hex: hex,
                            isSelected: hex.caseInsensitiveCompare(selected) == .orderedSame,
                            action: { select(hex) })
            }
        }
    }

    /// The 60–140 % slider. Kept free of `step:` — an earlier pass found that
    /// giving AppKit a step makes it draw tick marks the design does not have.
    private var scaleControl: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { store.settings.scale },
                    set: { store.setScale($0) }
                ),
                in: HeatmapMetrics.scaleRange
            )
            HStack {
                Text("60%")
                Spacer()
                Text("100%")
                Spacer()
                Text("140%")
            }
            .font(.system(size: 10))
            .foregroundStyle(SettingsTokens.ink35)
        }
    }

    /// The mockup's "Цвета и масштаб" card: two swatch rows and the scale
    /// slider, separated by full-width hairlines.
    private var colorsAndScaleCard: some View {
        GlassGroup(padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
            swatchRow(
                title: s.accentColor,
                subtitle: s.accentHint,
                options: Palette.presets.map(\.hex),
                selected: store.settings.accent,
                select: { store.setAccent($0) }
            )
            RowDivider().padding(.vertical, 14)
            swatchRow(
                title: s.accentColorBad,
                subtitle: s.accentBadHint,
                options: Palette.badPresets.map(\.hex),
                selected: store.settings.accentBad,
                select: { store.setAccentBad($0) }
            )
            RowDivider().padding(.vertical, 14)
            scaleRow
        }
    }

    private func swatchRow(
        title: String,
        subtitle: String,
        options: [String],
        selected: String,
        select: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 16) {
            RowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 16)
            // The mockup's 8px gap plus the 4pt of ring slack each swatch
            // reserves internally.
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { hex in
                    ColorSwatch(
                        hex: hex,
                        isSelected: hex.caseInsensitiveCompare(selected) == .orderedSame,
                        action: { select(hex) }
                    )
                }
            }
        }
    }

    private var scaleRow: some View {
        let percent = Int((store.settings.scale * 100).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                RowLabel(title: s.widgetScale, subtitle: s.widgetScaleHint)
                Spacer(minLength: 16)
                Text("\(percent)%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(SettingsTokens.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(SettingsTokens.accent.opacity(0.12)))
            }
            // No `step:` – on macOS that makes the slider draw tick marks
            // along the track, which the design's plain accent-coloured slider
            // does not have. Rounding happens in the setter instead, so the
            // value is still a whole percent.
            Slider(
                value: Binding(
                    get: { store.settings.scale },
                    set: { store.setScale(((($0) * 100).rounded()) / 100) }
                ),
                in: HeatmapMetrics.scaleRange
            )
            .tint(SettingsTokens.accent)
            // The mockup's 60 / 100 / 140 tick labels.
            HStack {
                Text("\(Int(HeatmapMetrics.scaleRange.lowerBound * 100))%")
                Spacer()
                Text("100%")
                Spacer()
                Text("\(Int(HeatmapMetrics.scaleRange.upperBound * 100))%")
            }
            .font(.system(size: 11))
            .foregroundStyle(SettingsTokens.ink40)
        }
    }

    /// Liquid glass and language. Not in the handoff – both are shipped
    /// features the design does not cover, so they get the mockup's own card
    /// treatment rather than being dropped or left looking foreign.
    private var appearanceCard: some View {
        GlassGroup {
            HStack(spacing: 16) {
                RowLabel(title: s.liquidGlass, subtitle: s.liquidGlassHint)
                Spacer(minLength: 16)
                SettingsSwitch(isOn: Binding(
                    get: { store.settings.liquidGlass },
                    set: { store.setLiquidGlass($0) }
                ))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            RowDivider(inset: 18)

            HStack(spacing: 16) {
                RowLabel(title: s.language)
                Spacer(minLength: 16)
                Picker("", selection: Binding(
                    get: { store.settings.language },
                    set: { store.setLanguage($0) }
                )) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName(s)).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    /// The push-navigation row. Summary counts every identifier the catalog
    /// knows about, so it answers "is anything being missed?" at a glance.
    private var appsSitesRow: some View {
        let all = store.allCandidates()
        let tracked = all.filter { store.isTracked($0.key, kind: $0.kind) }.count
        return GlassGroup {
            HoverRow(highlight: SettingsTokens.accent.opacity(0.12), action: onOpenAppsSites) {
                HStack(spacing: 16) {
                    RowLabel(title: s.appsSitesTitle,
                             subtitle: s.trackedSummary(tracked, of: all.count))
                    Spacer(minLength: 16)
                    Text("\u{203A}")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SettingsTokens.ink35)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
    }

    /// Two states, per the handoff: warning orange without access (plus the
    /// button), mint with it (no button – there is nothing left to do).
    private var accessCard: some View {
        let granted = access == .granted
        let tint = granted ? SettingsTokens.mint : SettingsTokens.warn
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(tint.opacity(0.25), lineWidth: 3).padding(-1.5))
                Text(granted ? s.accessGranted : s.accessDenied)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SettingsTokens.ink85)
            }
            Text(granted ? s.accessGrantedBody : s.accessDeniedBody)
                .font(.system(size: 12))
                .foregroundStyle(SettingsTokens.ink55)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !granted {
                Button(action: { FullDiskAccess.openSystemSettings() }) {
                    Text(s.openSystemSettings)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(SettingsTokens.accent)
                                .shadow(color: SettingsTokens.accent.opacity(0.4), radius: 8, y: 3)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tint.opacity(0.45), lineWidth: 1)
                )
        )
    }
}

// MARK: - Screen 2 · Приложения и сайты

/// Which classification a row carries. The handoff models neutral as a real,
/// selectable third state rather than "no value", so the UI needs a concrete
/// case for it even though `Settings.categories` stores it as an absent key.
private enum CategoryFilter: String, CaseIterable, Hashable {
    case all, useful, neutral, harmful

    /// The concrete category this filter keeps, or nil for «Все» (no filter).
    /// Neutral is now a real stored case, so it maps to `.neutral`, not nil.
    var category: Category? {
        switch self {
        case .useful: return .useful
        case .neutral: return .neutral
        case .harmful: return .destructive
        case .all: return nil
        }
    }
}

struct AppsSitesSettingsView: View {
    /// Chips, the search field and site avatars are all glass surfaces —
    /// they must follow the material like everything else on the main screen.
    @Environment(\.kiGlass) private var glass
    @ObservedObject var store: SettingsStore
    let onBack: () -> Void

    private var s: L10n { L10n(store.settings.language) }
    @State private var query = ""
    @State private var filter: CategoryFilter = .all
    @State private var appsExpanded = false
    @State private var showingAdd = false
    @State private var addKey = ""
    @State private var addKind: FilterKind = .app

    /// How many apps are shown before "Показать ещё N". Searching or filtering
    /// reveals everything that matched – the cap exists to keep the default
    /// view short, not to hide search results.
    private static let collapsedAppCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backLink
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    searchField
                    chipRow
                    legendHint
                    section(title: s.sectionApps, kind: .app)
                    section(title: s.sectionSites, kind: .site)
                    addManuallyButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
    }

    private var backLink: some View {
        Button(action: onBack) {
            Text(s.backToSettings)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(SettingsTokens.accent)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        TextField(s.searchPlaceholder, text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(SettingsTokens.ink85)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(glass.fieldFill)
                    .overlay(Capsule().strokeBorder(glass.groupBorder, lineWidth: 1))
            )
    }

    /// Filter chips with live counts. Counts are of *everything*, not of the
    /// current search – they describe the catalog, and a count that changed as
    /// you typed would be answering a different question than the label asks.
    private var chipRow: some View {
        let all = store.allCandidates()
        var counts: [CategoryFilter: Int] = [.all: all.count, .useful: 0, .neutral: 0, .harmful: 0]
        // Effective category, so an unclassified row counts under its default
        // (harmful) — the chip counts match the colours the widget will show.
        for row in all {
            switch store.effectiveCategory(of: row.key) {
            case .useful: counts[.useful, default: 0] += 1
            case .neutral: counts[.neutral, default: 0] += 1
            case .destructive: counts[.harmful, default: 0] += 1
            }
        }
        return HStack(spacing: 6) {
            ForEach(CategoryFilter.allCases, id: \.self) { option in
                chip(option, count: counts[option] ?? 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ option: CategoryFilter, count: Int) -> some View {
        let active = filter == option
        let tint: Color
        switch option {
        case .useful: tint = SettingsTokens.accent
        case .harmful: tint = SettingsTokens.bad
        case .all: tint = SettingsTokens.ink(0.7)
        case .neutral: tint = SettingsTokens.ink(0.6)
        }
        // Active fill: the chip's own colour for the two classified ones, and
        // a neutral ink for "все"/"нейтральные" – those are not a category
        // with a colour of its own.
        let fill: Color = {
            switch option {
            case .useful: return SettingsTokens.accent
            case .harmful: return SettingsTokens.bad
            case .all, .neutral: return SettingsTokens.ink65
            }
        }()
        let label: String = {
            switch option {
            case .all: return s.filterAll
            case .useful: return s.filterUseful
            case .neutral: return s.filterNeutral
            case .harmful: return s.filterHarmful
            }
        }()

        return Button {
            filter = option
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .opacity(0.65)
            }
            .foregroundStyle(active ? Color.white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(active ? fill : glass.fieldFill)
                    .overlay(
                        Capsule().strokeBorder(
                            active ? Color.clear : glass.groupBorder,
                            lineWidth: 1
                        )
                    )
            )
            .fixedSize(horizontal: true, vertical: false) // white-space: nowrap
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: active)
    }

    private var legendHint: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: store.settings.accent))
                .frame(width: 10, height: 10)
            Text(s.categoryLegendUseful)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(hex: store.settings.accentBad))
                .frame(width: 10, height: 10)
            Text(s.categoryLegendHarmful)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(SettingsTokens.ink50)
        .padding(.horizontal, 4)
    }

    /// Search matches the display name *and* the raw identifier, so
    /// `com.apple.` finds Apple's apps even though the list shows "Safari".
    private func matches(_ row: FilterCandidate) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hitsQuery = q.isEmpty
            || row.displayName.lowercased().contains(q)
            || row.key.lowercased().contains(q)
        guard hitsQuery else { return false }
        guard filter != .all else { return true }
        // Effective, so «Вредные» includes the unclassified-by-default rows.
        return store.effectiveCategory(of: row.key) == filter.category
    }

    private var isNarrowed: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all
    }

    private func section(title: String, kind: FilterKind) -> some View {
        let matched = store.candidates(kind: kind).filter(matches)
        // Only the apps list collapses; the sites list is short by nature.
        let collapses = kind == .app && !isNarrowed && !appsExpanded
        let visible = collapses ? Array(matched.prefix(Self.collapsedAppCount)) : matched
        let hidden = matched.count - visible.count

        return VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(SettingsTokens.ink45)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

            if matched.isEmpty {
                Text(isNarrowed ? s.nothingFound : s.sectionEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTokens.ink50)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                GlassGroup {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        candidateRow(row)
                    }
                    if hidden > 0 {
                        RowDivider()
                        Button { appsExpanded = true } label: {
                            Text(s.showMore(hidden))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(SettingsTokens.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// One row: avatar, name, three-way category segment, tracking switch.
    /// The segment disappears when tracking is off and the whole row dims –
    /// classifying something that isn't counted has no meaning.
    private func candidateRow(_ row: FilterCandidate) -> some View {
        let tracked = store.isTracked(row.key, kind: row.kind)
        return HStack(spacing: 10) {
            avatar(for: row)
            Text(row.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTokens.ink85)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.key)
            Spacer(minLength: 8)
            if tracked {
                CategorySegment(
                    // Effective, so an untouched row shows its default (harmful)
                    // as the selected segment rather than a phantom neutral.
                    current: store.effectiveCategory(of: row.key),
                    strings: s,
                    select: { store.setCategory($0, for: row.key) }
                )
            }
            SettingsSwitch(
                isOn: Binding(
                    get: { tracked },
                    set: { store.setTracked(row.key, kind: row.kind, on: $0) }
                ),
                width: 38,
                height: 22
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(tracked ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.15), value: tracked)
    }

    /// Apps get a rounded square with the initial; sites get a bordered circle
    /// – the same distinction the mockup draws, and the one macOS users
    /// already read as "app icon" vs "favicon".
    private func avatar(for row: FilterCandidate) -> some View {
        let initial = String(row.displayName.prefix(1)).uppercased()
        let tint = SettingsTokens.avatarColor(for: row.key)
        return Group {
            if row.kind == .app {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint)
                    .overlay(
                        Text(initial)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )
            } else {
                Circle()
                    .fill(glass.fieldFill)
                    .overlay(Circle().strokeBorder(SettingsTokens.ink(0.1), lineWidth: 1))
                    .overlay(
                        Text(initial)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                    )
            }
        }
        .frame(width: 28, height: 28)
    }

    private var addManuallyButton: some View {
        HStack {
            Spacer()
            Button { showingAdd = true } label: {
                Text(s.addManuallyButton)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTokens.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(SettingsTokens.accent.opacity(0.12))
                            .overlay(Capsule().strokeBorder(SettingsTokens.accent.opacity(0.35), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingAdd) { addManualPopover }
            Spacer()
        }
    }

    private var addManualPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.addManually).font(.system(size: 13, weight: .bold)).foregroundStyle(SettingsTokens.ink90)
            Picker("", selection: $addKind) {
                Text(s.kindApp).tag(FilterKind.app)
                Text(s.kindSite).tag(FilterKind.site)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(addKind == .app ? s.bundleIdPlaceholder : s.domainPlaceholder, text: $addKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Spacer()
                Button(s.addButton) {
                    store.addManual(addKey, kind: addKind)
                    addKey = ""
                    showingAdd = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// The mockup's `+ · −` segmented control: a pill of three 26×22 buttons.
/// Replaces an earlier dropdown menu – the glyphs are the same vocabulary the
/// filter chips use, and a classification is a one-click change here.
/// Optical centring for a lone `+`, `·` or `−` in a fixed frame.
///
/// `Text` centres the *line box* – ascender to descender – not the glyph you
/// can see. All three of these are drawn on the font's math axis, which sits
/// well below the middle of that box, so all three render low by the same
/// amount: measured at **1.19 pt** for 13 pt bold system, inside a 22 pt pill.
/// That is what reads as "not exactly in the centre".
///
/// Derived from live font metrics rather than pasted in as a constant, so it
/// stays correct if the size or weight is ever changed. Horizontal centring
/// needs no such help – these glyphs are centred on their advance width to
/// within 0.06 pt, which was measured too before assuming it.
enum MathGlyphCentring {
    static let size: CGFloat = 13

    /// Negative – the glyph has to move *up*. Verified by rendering the real
    /// button and locating its ink: +1.19 pt before, −0.06 pt after.
    static let verticalCorrection: CGFloat = {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2212}", attributes: [.font: font])
        )
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let lineBoxCentre = (font.ascender + font.descender) / 2
        return ink.midY - lineBoxCentre
    }()
}

private struct CategorySegment: View {
    /// Now three concrete values, not `Category?` with nil-as-neutral: neutral
    /// is a real stored case, and the segment always sends an explicit choice.
    let current: Category
    let strings: L10n
    let select: (Category) -> Void

    /// Order is deliberate: positive, neutral, negative, left to right, like the
    /// diverging scale on the widget.
    private struct Option: Hashable {
        let value: Category
        let glyph: String
    }

    private static let options: [Option] = [
        Option(value: .useful, glyph: "+"),
        Option(value: .neutral, glyph: "\u{00B7}"),
        Option(value: .destructive, glyph: "\u{2212}"),
    ]

    private func tint(_ value: Category) -> Color {
        switch value {
        case .useful: return SettingsTokens.accent
        case .destructive: return SettingsTokens.bad
        case .neutral: return SettingsTokens.ink45
        }
    }

    private func tip(_ value: Category) -> String {
        switch value {
        case .useful: return strings.categoryUsefulTip
        case .destructive: return strings.categoryHarmfulTip
        case .neutral: return strings.categoryNeutralTip
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options, id: \.self) { option in
                let active = current == option.value
                Button { select(option.value) } label: {
                    Text(option.glyph)
                        .font(.system(size: MathGlyphCentring.size, weight: .bold))
                        .foregroundStyle(active ? Color.white : SettingsTokens.ink40)
                        // Offset before the frame, so the pill stays put and
                        // only the glyph inside it moves.
                        .offset(y: MathGlyphCentring.verticalCorrection)
                        .frame(width: 26, height: 22)
                        .background(
                            Capsule().fill(active ? tint(option.value) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(tip(option.value))
            }
        }
        .padding(2)
        .background(Capsule().fill(SettingsTokens.ink06))
        .animation(.easeInOut(duration: 0.15), value: current)
    }
}

// MARK: - Root

enum SettingsScreen: Hashable {
    case main
    case appsSites

    /// The handoff gives each screen its own width (440 / 470). The window
    /// animates between them on push, like System Settings does.
    var width: CGFloat {
        switch self {
        case .main: return 456
        case .appsSites: return 470
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    private var s: L10n { L10n(store.settings.language) }
    @State private var screen: SettingsScreen

    /// Told about width changes so the `NSWindow` can follow the design's
    /// per-screen width. Set by the window controller.
    var onScreenChange: (SettingsWidthRequest) -> Void = { _ in }

    init(store: SettingsStore,
         initialScreen: SettingsScreen = .main,
         onScreenChange: @escaping (SettingsWidthRequest) -> Void = { _ in }) {
        self.store = store
        self._screen = State(initialValue: initialScreen)
        self.onScreenChange = onScreenChange
    }

    var body: some View {
        // Derived here, not injected at window creation: this view observes the
        // store, so flipping «Материал» re-evaluates the body and every glass
        // surface below picks the new value up immediately.
        content.environment(\.kiGlass, KiGlassStyle(intense: store.settings.liquidGlass))
    }

    private var content: some View {
        VStack(spacing: 0) {
            titleBar
            Group {
                switch screen {
                case .main:
                    MainSettingsView(store: store) {
                        withAnimation(.easeInOut(duration: 0.22)) { screen = .appsSites }
                        onScreenChange(.init(width: SettingsScreen.appsSites.width))
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                case .appsSites:
                    AppsSitesSettingsView(store: store) {
                        withAnimation(.easeInOut(duration: 0.22)) { screen = .main }
                        onScreenChange(.init(width: SettingsScreen.main.width))
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsBackground())
    }

    /// The window's own header. The real traffic lights are drawn by AppKit
    /// over this strip (`titlebarAppearsTransparent` + hidden title in the
    /// controller), so the row only reserves room for them and centres the
    /// title the way the mockup does.
    private var titleBar: some View {
        Text(screen == .main ? s.settingsTitle : s.appsSitesTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SettingsTokens.ink75)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 70) // clear of the traffic lights on both sides
            .padding(.vertical, 14)
    }
}

/// Carries a requested window width out of SwiftUI to the controller.
struct SettingsWidthRequest {
    let width: CGFloat
}

/// The mockup's glass: real wallpaper blur, a faint wash of the brand colours,
/// and the white 0.66 → 0.38 gradient on top. The colour blobs are the
/// mockup's own background – in the mockup they sit on a lavender canvas, and
/// without them the window reads as plain grey frosted glass rather than this
/// design's glass.
private struct SettingsBackground: View {
    @Environment(\.kiGlass) private var glass

    var body: some View {
        ZStack {
            if glass.intense {
                // Glass: real wallpaper blur, then the thin veil. The mockup's
                // blurred colour blobs are NOT drawn here — they belong to the
                // page its glass floats on, and painting them inside the window
                // would opaque out the very thing this material exists to show.
                VisualEffectBacking(material: .underWindowBackground)
                    .saturation(2.0)
                LinearGradient(colors: glass.veil, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                // Regular is `backdrop-filter: none` over a solid `#ececec` /
                // `#252527` — a plain opaque window, which is the whole point
                // of the variant.
                glass.windowFill
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Window controller

/// Owns the single settings window. Reused across "Настройки…" clicks –
/// closing the window just hides it (`isReleasedWhenClosed = false`), so
/// state like the search query survives a close/reopen within one app
/// session, matching how System Settings behaves.
final class SettingsWindowController: NSWindowController {
    private let store: SettingsStore

    init(store: SettingsStore, initialScreen: SettingsScreen = .main) {
        self.store = store

        let window = NSWindow(
            // Tall enough that the main screen fits without scrolling – it
            // carries one card more than the handoff's mockup (liquid glass +
            // language, which the design does not cover but the app ships).
            contentRect: NSRect(x: 0, y: 0, width: SettingsScreen.main.width, height: 780),
            // Height is resizable, width is not: the handoff's screens are
            // fixed-width panels (440 / 470) and the layout inside them is
            // tuned to that width. Height has to give, because the apps list
            // is unbounded.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // The mockup draws its own title bar: traffic lights at the left, a
        // centred 13/600 title, all sitting on the glass. Hiding AppKit's
        // title and letting content run under the title bar gets exactly that
        // while keeping the *real* traffic lights – drawn ones would look
        // right and behave wrong.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        // Appearance deliberately left unpinned so the window follows the
        // system theme – the handoff now ships a dark theme, and every token
        // this window draws with is themed to match (`KiGlass` / `KiInk`).
        // It used to be forced to `.aqua` because the design was light-only.

        super.init(window: window)

        let content = SettingsRootView(
            store: store,
            initialScreen: initialScreen,
            onScreenChange: { [weak self] request in self?.applyWidth(request.width) }
        )
        // One place decides the material for this whole surface.
        let hosting = NSHostingView(
            // No `.environment(\.kiGlass, …)` here: evaluated once at window
            // creation, it froze the material for the window's whole life, so
            // the segmented control changed settings.json and nothing else.
            // `SettingsRootView` now derives it from its observed store.
            rootView: content
        )
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        applyWidth(initialScreen.width, animated: false)
        window.isReleasedWhenClosed = false
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pins the window to a screen's design width and animates the change.
    /// Min and max width are set equal so the user cannot drag the window off
    /// the width its layout was designed for.
    private func applyWidth(_ width: CGFloat, animated: Bool = true) {
        guard let window else { return }
        window.minSize = NSSize(width: width, height: 380)
        window.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        var frame = window.frame
        guard abs(frame.width - width) > 0.5 else { return }
        // Only the width moves, so the top edge stays put on its own (Cocoa's
        // origin is the bottom-left and the height is unchanged). Widening is
        // anchored on the left edge, which is where the traffic lights are.
        frame.size.width = width
        window.setFrame(frame, display: true, animate: animated)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
