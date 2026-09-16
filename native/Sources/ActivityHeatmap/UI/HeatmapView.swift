import AppKit
import SwiftUI

/// The real widget. Port of the Übersicht prototype's `index.jsx`'s
/// `Heatmap`/`Card`/`Message` components – grid math, quartile
/// thresholds, tooltip placement and copy are all deliberately identical
/// to the reference so the two engines read as the same product.
///
/// Two things the web version didn't have to deal with:
///   - dragging moves the actual `NSWindow` (`DesktopWindow.swift`), not a
///     CSS transform, so this file only renders; window geometry lives in
///     `WindowDragCoordinator` / `DesktopWindowController`.
///   - the card's size is data-dependent (loading vs. grid vs. error
///     message), so `DesktopWindow.swift`'s `AutoSizingHostingView` re-measures
///     and repositions the window on every layout pass.

// MARK: - State

enum HeatmapState {
    case loading
    case data(days: [String: DayStats], tracked: Bool)
    case noAccess
    case failed(String)
}

/// Message copy shared between what's rendered (`MessageCard`, below) and
/// what's measured (`HeatmapLayout.size(for:...)` in `DesktopWindow.swift`)
/// so the two can never drift out of sync.
enum HeatmapCopy {
    /// Measurement paths (`HeatmapLayout`) need the same text the view will
    /// render, so both go through the same `L10n` instance.
    static var strings = L10n(Settings().language)
    static var loadingBody: String { strings.loadingBody }
    static var noAccessTitle: String { strings.noAccessTitle }
    static var noAccessBody: String { strings.noAccessBody }
    static var failedTitle: String { strings.failedTitle }
    /// Arbitrary `Error` descriptions can be enormous (a wrapped `NSError`
    /// prints its entire `userInfo`); cap what's ever laid out or
    /// measured so a verbose underlying error can't blow the card up.
    static func failedBody(_ detail: String) -> String {
        detail.count > 300 ? String(detail.prefix(300)) + "…" : detail
    }
}

/// Tiny observable box so SwiftUI can react to state coming from
/// `Store`/`Knowledge` on a background queue. Also carries the theme
/// (accent ramp + layout knobs) computed from `Settings`.
final class HeatmapViewModel: ObservableObject {
    @Published var state: HeatmapState = .loading
    @Published var accentRamp: [String] = Palette.ramp(forAccent: Settings().accent).ramp
    /// Ramp for negative-balance days. Same shape as `accentRamp`; which one a
    /// tile uses is decided by the sign of its balance.
    @Published var badRamp: [String] = Palette.ramp(forAccent: Settings().accentBad).ramp
    /// Single proportional scale for the whole card – the design is one fixed
    /// layout (660pt wide), so width and height are never set independently.
    @Published var scale: CGFloat = 1
    @Published var showLegend: Bool = Settings().showLegend
    @Published var liquidGlass: Bool = Settings().liquidGlass
    /// Harmful weight applied to the score (tile colour + balance figure). 1.0
    /// is the honest 1:1; changing it re-renders without re-aggregating, since
    /// the stored `useful`/`destructive` seconds don't change, only how the
    /// score weighs them.
    @Published var harmfulWeight: Double = Settings().clampedHarmfulWeight
    /// The day whose detail is pinned open by a click (nil = none). The tooltip
    /// shows the brief top-3 on hover; clicking a tile pins that day and expands
    /// the same card in place to the full breakdown.
    @Published var pinnedDay: String?
    /// Current settings, so the pinned detail can colour each app/site by its
    /// live category. Refreshed from `applyToWidget` like everything else.
    @Published var settingsSnapshot = Settings()
    /// Localised copy, refreshed whenever Settings change.
    @Published var strings: L10n = L10n(Settings().language)
}

// MARK: - Grid math (port of buildGrid / buildThresholds / levelFor)

struct GridCell: Identifiable {
    let iso: String
    let row: Int
    let col: Int
    let future: Bool
    /// Today gets an outline whatever its fill. A day in progress usually
    /// carries a small balance, and the first coloured step differs from the
    /// empty one by only ~9% in RGB – over blurred wallpaper that reads as
    /// "today is not counted at all", which is what prompted this.
    let isToday: Bool
    var id: String { iso }
}

enum HeatmapGrid {
    static let weeks = 13
    static let rows = 7

    /// GitHub-style grid: 13 columns of weeks, Monday-first, last column
    /// is this week.
    static func build(today: Date = Date(), calendar: Calendar = .current) -> [GridCell] {
        var cal = calendar
        cal.timeZone = calendar.timeZone
        let startOfToday = cal.startOfDay(for: today)
        let weekday = cal.component(.weekday, from: startOfToday) // 1 = Sunday
        let mondayOffset = (weekday + 5) % 7 // days since Monday
        guard let gridStart = cal.date(byAdding: .day, value: -(mondayOffset + (weeks - 1) * 7), to: startOfToday) else {
            return []
        }
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var cells: [GridCell] = []
        cells.reserveCapacity(weeks * rows)
        for col in 0..<weeks {
            for row in 0..<rows {
                guard let date = cal.date(byAdding: .day, value: col * 7 + row, to: gridStart) else { continue }
                let iso = formatter.string(from: date)
                cells.append(GridCell(iso: iso, row: row, col: col,
                                      future: date > startOfToday,
                                      isToday: date == startOfToday))
            }
        }
        return cells
    }

    /// Quartiles over the non-empty days, so the ramp adapts to how the
    /// mac is actually used (not a fixed absolute scale).
    /// Quartile cut-offs, computed separately for positive and negative days
    /// over the *magnitude* of the balance. Two scales rather than one because
    /// the two sides are usually lopsided: a couple of heavy bad days would
    /// otherwise flatten every good day into the palest step.
    struct Thresholds: Equatable {
        var positive: [Int] = [0, 0, 0]
        var negative: [Int] = [0, 0, 0]
    }

    static func thresholds(days: [String: DayStats], harmfulWeight: Double = 1) -> Thresholds {
        func quartiles(_ values: [Int]) -> [Int] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [0, 0, 0] }
            func at(_ q: Double) -> Int {
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
            }
            return [at(0.25), at(0.5), at(0.75)]
        }
        let scores = days.values.map { $0.weightedScore(harmfulWeight) }
        return Thresholds(
            positive: quartiles(scores.filter { $0 > 0 }),
            negative: quartiles(scores.filter { $0 < 0 }.map { -$0 })
        )
    }

    /// Signed intensity of a day: `sign` picks the ramp (good vs bad),
    /// `level` the step within it. A zero balance – no data, or classified
    /// time that cancelled out exactly, or purely unclassified activity –
    /// renders as the empty step of the good ramp.
    struct Level: Equatable {
        let sign: Int   // +1, -1, or 0
        let step: Int   // 0...4
    }

    static func level(score: Int?, thresholds: Thresholds) -> Level {
        guard let score, score != 0 else { return Level(sign: 0, step: 0) }
        let magnitude = abs(score)
        let scale = score > 0 ? thresholds.positive : thresholds.negative
        let step: Int
        if magnitude <= scale[0] { step = 1 }
        else if magnitude <= scale[1] { step = 2 }
        else if magnitude <= scale[2] { step = 3 }
        else { step = 4 }
        return Level(sign: score > 0 ? 1 : -1, step: step)
    }
}

// MARK: - Window sizing

/// Computes the card's pixel size *analytically* instead of asking
/// SwiftUI/AppKit to measure the live view. This exists because a
/// `.fixedSize()` + `GeometryReader` self-measurement trick was tried
/// first (the natural approach for a data-dependent window size) and hit
/// a reproducible SwiftUI bug: a view containing an `if let` conditional
/// branch (e.g. `MessageCard`'s optional title) reports `(0, 0)` when
/// measured that way, even though the *exact same view* renders correctly
/// under normal window display with a real proposed size. See
/// `DesktopWindowController` in DesktopWindow.swift for how this is used
/// and history/STAGE3.md for the full writeup. Every constant here must be kept
/// in sync with the paddings/spacings actually used by `MessageCard` and
/// `HeatmapCardView.grid(days:)` below.
enum HeatmapLayout {
    static let messageWidth: CGFloat = 250
    private static let messagePadding = EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24)
    private static let messageSpacing: CGFloat = 4

    private static let cardPadding = EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24)
    private static let headerBottomSpacing: CGFloat = 18
    private static let legendTopSpacing: CGFloat = 16

    static func size(for state: HeatmapState, scale: CGFloat, showLegend: Bool, glass: Bool) -> CGSize {
        switch state {
        case .loading:
            return messageSize(title: nil, body: HeatmapCopy.loadingBody, glass: glass)
        case .noAccess:
            return messageSize(title: HeatmapCopy.noAccessTitle, body: HeatmapCopy.noAccessBody, glass: glass)
        case .failed(let detail):
            return messageSize(title: HeatmapCopy.failedTitle, body: HeatmapCopy.failedBody(detail), glass: glass)
        case .data:
            return gridSize(scale: scale, showLegend: showLegend, glass: glass)
        }
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    private static func messageSize(title: String?, body: String, glass: Bool) -> CGSize {
        var height: CGFloat = 0
        if let title {
            height += textHeight(title, font: .systemFont(ofSize: 12, weight: .bold), width: messageWidth)
            height += messageSpacing
        }
        height += textHeight(body, font: .systemFont(ofSize: 12), width: messageWidth)
        // Message cards are unscaled (see `MessageCard`), but still need the
        // same shadow margin so the drop shadow isn't clipped square.
        let pad = HeatmapMetrics(scale: 1, glass: glass).shadowPad
        return CGSize(
            width: messageWidth + messagePadding.leading + messagePadding.trailing + pad * 2,
            height: height + messagePadding.top + messagePadding.bottom + pad * 2
        )
    }

    // Title line height vs. the pill's line height + its own vertical
    // padding – whichever is taller wins, same as the
    // HStack(alignment: .firstTextBaseline) in `header(tracked:m:)`.
    /// The header is a single line of text – today's date – so its height is
    /// just that line. The measured string is a worst case for the longest
    /// month name, since the real one changes daily and the window is sized
    /// from this number.
    private static func headerHeight(_ m: HeatmapMetrics) -> CGFloat {
        textHeight("30 сентября, воскресенье", font: .boldSystemFont(ofSize: m.titleSize), width: 10_000)
    }

    private static func legendHeight(_ m: HeatmapMetrics, showLegend: Bool) -> CGFloat {
        guard showLegend else { return 0 }
        return m.legendTop + max(
            textHeight("00 ч 00 мин всего", font: .systemFont(ofSize: m.totalSize, weight: .semibold), width: 10_000),
            m.swatch
        )
    }

    /// Distance from the card's top edge to the top of the resize grip.
    private static func handleOffset(_ m: HeatmapMetrics, showLegend: Bool) -> CGFloat {
        m.padTop + headerHeight(m) + m.headerBottom + m.gridHeight
            + legendHeight(m, showLegend: showLegend) + m.handleTop
    }

    /// Card size for the `.data` state, plus the shadow margin the window has
    /// to reserve. Mirrors `HeatmapMetrics` exactly – if one changes, so must
    /// the other, or the window will clip or float away from the card.
    private static func gridSize(scale: CGFloat, showLegend: Bool, glass: Bool) -> CGSize {
        let m = HeatmapMetrics(scale: scale, glass: glass)
        return CGSize(
            width: m.cardWidth + m.shadowPad * 2,
            height: handleOffset(m, showLegend: showLegend) + m.handleHeight
                + m.padBottom + m.shadowPad * 2
        )
    }

    /// Mouse target of the resize grip, in the same flipped, shadow-offset
    /// space as `headerRect`. `nil`-equivalent (`.zero`) outside `.data`: the
    /// message cards have no grip, exactly as they have no drag header.
    /// The whole card, in the same flipped, shadow-offset space as
    /// `headerRect`. The widget is moved by dragging anywhere in here (minus the
    /// resize grip) — not just the header. The header-only region left the
    /// widget unrecoverable once its top scrolled off the screen: with nothing
    /// grabbable on screen you could neither move it nor double-click-reset it
    /// (a user hit exactly this). `.zero` outside `.data`, like the others.
    static func cardRect(for state: HeatmapState, scale: CGFloat, showLegend: Bool, glass: Bool) -> CGRect {
        guard case .data = state else { return .zero }
        let m = HeatmapMetrics(scale: scale, glass: glass)
        let height = size(for: state, scale: scale, showLegend: showLegend, glass: glass).height - m.shadowPad * 2
        return CGRect(x: m.shadowPad, y: m.shadowPad, width: m.cardWidth, height: height)
    }

    static func scaleHandleRect(for state: HeatmapState, scale: CGFloat, showLegend: Bool, glass: Bool) -> CGRect {
        guard case .data = state else { return .zero }
        let m = HeatmapMetrics(scale: scale, glass: glass)
        return CGRect(
            x: m.shadowPad + (m.cardWidth - m.handleWidth) / 2,
            y: m.shadowPad + handleOffset(m, showLegend: showLegend) - m.handleHitInset,
            width: m.handleWidth,
            height: m.handleHeight + m.handleHitInset * 2
        )
    }

    /// Top-left of the tile grid, in the shadow-offset flipped space the other
    /// rects use. The grid sits below the header inside the card's padding —
    /// same box model `HeatmapCardView.grid` lays out, kept in sync by hand.
    private static func gridOrigin(_ m: HeatmapMetrics) -> CGPoint {
        CGPoint(x: m.shadowPad + m.padSide,
                y: m.shadowPad + m.padTop + headerHeight(m) + m.headerBottom)
    }

    /// The rect of one tile (`col` = week, `row` = weekday), for anchoring the
    /// day-detail popover. Same space as `cardRect`/`scaleHandleRect`.
    static func tileRect(col: Int, row: Int, for state: HeatmapState, scale: CGFloat, glass: Bool) -> CGRect {
        guard case .data = state else { return .zero }
        let m = HeatmapMetrics(scale: scale, glass: glass)
        let origin = gridOrigin(m)
        let step = m.tile + m.gap
        return CGRect(x: origin.x + CGFloat(col) * step,
                      y: origin.y + CGFloat(row) * step,
                      width: m.tile, height: m.tile)
    }

    /// Which tile a point falls on, or nil if it's in a gap / outside the grid.
    /// Used to turn a click into a day. Rejects the gaps between tiles so a
    /// click that just misses a tile doesn't snap to a neighbour.
    static func tile(at local: CGPoint, for state: HeatmapState, scale: CGFloat, glass: Bool) -> (col: Int, row: Int)? {
        guard case .data = state else { return nil }
        let m = HeatmapMetrics(scale: scale, glass: glass)
        let origin = gridOrigin(m)
        let step = m.tile + m.gap
        let dx = local.x - origin.x
        let dy = local.y - origin.y
        guard dx >= 0, dy >= 0 else { return nil }
        let col = Int(dx / step), row = Int(dy / step)
        guard col < HeatmapGrid.weeks, row < HeatmapGrid.rows else { return nil }
        // Inside the tile itself, not the gap after it.
        guard dx - CGFloat(col) * step <= m.tile, dy - CGFloat(row) * step <= m.tile else { return nil }
        return (col, row)
    }

    /// The draggable header band, in the hosting view's local (top-left
    /// origin, flipped – matching `NSHostingView`) coordinate space. `nil`
    /// outside the `.data` state: the loading/no-access/failed messages
    /// have no header and aren't draggable, matching index.jsx (only the
    /// real `Heatmap` component has an `ah-handle`; `Message` does not).
    /// Used by `AutoSizingHostingView` in DesktopWindow.swift for mouse
    /// hit-testing – see that file for why dragging is handled there
    /// instead of via a SwiftUI-side `.background()` NSViewRepresentable.
    static func headerRect(for state: HeatmapState, scale: CGFloat, glass: Bool) -> CGRect {
        guard case .data = state else { return .zero }
        let m = HeatmapMetrics(scale: scale, glass: glass)
        // Offset by the shadow margin: the card no longer starts at the
        // window's origin.
        return CGRect(
            x: m.shadowPad,
            y: m.shadowPad,
            width: m.cardWidth,
            height: m.padTop + headerHeight(m)
        )
    }
}

// MARK: - Formatting (port of formatDuration / formatDate / plural)

enum HeatmapFormat {
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = Int((Double(seconds % 3600) / 60).rounded())
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    private static let months = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    static func date(iso: String) -> String {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
        return "\(parts[2]) \(months[parts[1] - 1])"
    }
}

// MARK: - Tokens (colours/metrics not covered by the data-driven ramp)

enum HeatmapTokens {
    /// Design ink is rgba(20,32,28,·); each opacity below is taken verbatim
    /// from `Activity Widget.dc.html`.
    /// KiTheme.swift: `KiColor.ink = rgb(30,25,50)`. The widget HTML used
    /// rgba(20,32,28) but the designer's SwiftUI unified everything on the
    /// app-wide ink, which is a touch more violet.
    /// Light `rgb(30,25,50)`, dark `rgba(238,240,250,α)` – see `KiInk`. The
    /// alphas below are the mockup's and are the *same* in both themes: the
    /// dark theme changes the ink itself, not how hard each label is pushed.
    static let inkBase = KiInk.widget
    static let ink = inkBase.opacity(0.92)        // title
    static let inkSoft = inkBase.opacity(0.55)    // pill
    static let inkTotal = inkBase.opacity(0.60)   // legend total
    static let inkLegend = inkBase.opacity(0.50)  // "Негатив"/"Польза"

    /// Resize grip at rest. Not `inkBase.opacity(0.18)`: on dark that ink is
    /// nearly white and 18 % of it disappears into the card, so the handoff
    /// raises it to `rgba(255,255,255,0.22)` outright.
    static let handle = Color.themed(light: KiInk.light.opacity(0.18), dark: .white.opacity(0.22))

    /// Zero-balance tile. Opaque `#efedf3` on light; on dark deliberately
    /// *translucent* white so the card's blur reads through the empty days
    /// instead of them becoming grey plates.
    static let neutralTile = Color.themed(light: Color(hex: Palette.neutral), dark: .white.opacity(0.07))

    /// Lift under a hovered tile. Stays dark ink in both themes – the mockup
    /// does not theme it, and a near-white glow on the dark card would read as
    /// the tile emitting light rather than rising off the surface.
    static let tileShadow = KiInk.light.opacity(0.25)
    /// Balance colours in the tooltip. Fixed rather than derived from the
    /// accents: they label a sign, and must stay readable whatever ramp
    /// colours the user picks.
    static let good = Color(red: 0x2f / 255, green: 0x9e / 255, blue: 0x74 / 255)
    static let bad = Color(red: 0xd1 / 255, green: 0x6c / 255, blue: 0x2f / 255)
}

/// Every number here is lifted 1:1 from the approved design
/// (`Activity Widget.dc.html`) at scale 1.0, then multiplied by `scale`.
/// The design is a 660pt-wide card; nothing is "adjusted to taste" – an
/// earlier port silently shrank everything to ~57% and the result no longer
/// read as the same design.
struct HeatmapMetrics {
    let scale: CGFloat
    /// `Settings.liquidGlass`. The handoff's "Glass Version" is a different
    /// *material*, and three of its numbers are geometry, not colour: a wider
    /// corner radius, a thicker rim, and a much deeper shadow. The last one
    /// changes the window's size, which is why this has to live here in the
    /// metrics rather than in `CardBackground` alone.
    let glass: Bool

    init(scale: CGFloat = 1, glass: Bool = true) {
        self.scale = min(max(scale, 0.4), 3.0)
        self.glass = glass
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    /// The range the resize grip may drive the widget through. The design
    /// states two: "0.65–1.25" for the drag itself and "60–140 %" for the
    /// settings slider it shares a value with. One value with two different
    /// reachable ranges would leave a dead zone at each end of the slider, so
    /// both controls use the wider, explicitly-shared 60–140 %.
    static let scaleRange: ClosedRange<Double> = 0.6...1.4
    /// Vertical travel, in points, for a full 1.0 change of scale – the
    /// mockup's `(ev.clientY - startY) / 300`.
    static let scaleDragTravel: CGFloat = 300

    // Card: width 660, radius 34, padding 30/32/24, border 1px white .55
    var cardWidth: CGFloat { s(660) }
    /// One radius for both materials now — the HIG pass replaced 34/42 with a
    /// single 28 (`KiRadius.widget`).
    var cardRadius: CGFloat { s(KiRadius.widget) }
    var padTop: CGFloat { s(30) }
    var padSide: CGFloat { s(32) }
    var padBottom: CGFloat { s(24) }
    var borderWidth: CGFloat { max(1, s(glass ? 1.5 : 1)) }

    // Header: title 27/700 tracking -0.4, pill 15/600 padding 5×14, gap 26
    var titleSize: CGFloat { s(27) }
    var titleTracking: CGFloat { s(-0.4) }
    var headerBottom: CGFloat { s(26) }

    // Grid: gap 8, tile radius 9. Tiles are `1fr` in CSS – they divide the
    // content width, they are not a fixed size.
    var gap: CGFloat { s(8) }
    var tileRadius: CGFloat { s(9) }
    var contentWidth: CGFloat { cardWidth - padSide * 2 }
    var tile: CGFloat {
        (contentWidth - gap * CGFloat(HeatmapGrid.weeks - 1)) / CGFloat(HeatmapGrid.weeks)
    }
    var gridHeight: CGFloat {
        tile * CGFloat(HeatmapGrid.rows) + gap * CGFloat(HeatmapGrid.rows - 1)
    }

    // Legend: margin-top 24, total 14/600, labels 13/500, swatch 14 r4.5, gap 6
    var legendTop: CGFloat { s(24) }
    var totalSize: CGFloat { s(14) }
    var legendSize: CGFloat { s(13) }
    var swatch: CGFloat { s(14) }
    var swatchRadius: CGFloat { s(4.5) }
    var legendGap: CGFloat { s(6) }
    var legendLabelGap: CGFloat { s(4) }

    // Resize grip: margin-top 18, 64×6, fully rounded.
    var handleTop: CGFloat { s(18) }
    var handleWidth: CGFloat { s(64) }
    var handleHeight: CGFloat { s(6) }
    /// The grip is 6pt tall – too thin to hit reliably. The *drawn* bar stays
    /// the design's size; only the mouse target grows, into the card's bottom
    /// padding where nothing else is interactive.
    var handleHitInset: CGFloat { s(7) }

    // Drop shadow. CSS `0 24px 60px` – SwiftUI's radius is roughly half the
    // CSS blur. The window must reserve room for it: sized flush to the card,
    // the shadow is clipped at the window edge and reads as square corners
    // behind a rounded card (observed on screen).
    // Glass `0 28px 70px` + `0 2px 8px`; regular `0 22px 50px`. Kept in step
    // with `KiGlassStyle`, which is where the design values live.
    private var style: KiGlassStyle { KiGlassStyle(intense: glass) }
    var shadowRadius: CGFloat { s(style.shadowRadius) }
    var shadowY: CGFloat { s(style.shadowY) }
    var closeShadowRadius: CGFloat { s(style.closeShadowRadius) }
    var closeShadowY: CGFloat { s(style.closeShadowY) }
    /// The margin the window reserves so the shadow isn't clipped square.
    /// It has to clear `shadowY + shadowRadius` with room to spare – 85pt for
    /// the glass version against 42pt for the base one, keeping the same
    /// ~1.33x headroom the base card was already verified with.
    var shadowPad: CGFloat { s(glass ? 80 : 60) }
}

// MARK: - Card chrome

/// Real glass, per ARCHITECTURE.md risk 2: `NSVisualEffectView` with
/// `.behindWindow` measurably blurs the desktop wallpaper; a translucent
/// `Color` fill does not (nothing valid to sample "behind" a transparent
/// window). Do not swap this for a flat fill.
struct VisualEffectBacking: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        // Appearance is deliberately NOT pinned any more. It used to be forced
        // to `.aqua`, because the design was a light card only and the material
        // going dark in Dark Mode left the white overlay fighting a dark base.
        // The handoff now ships a dark theme, so the material must follow the
        // system and the overlay above it is themed to match (`KiGlass`).
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

private struct CardBackground: View {
    let metrics: HeatmapMetrics
    let liquid: Bool

    private var style: KiGlassStyle { KiGlassStyle(intense: liquid) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
        // The blur underneath is the system's, the layers on top are the
        // design's. That split is deliberate: `NSVisualEffectView` really does
        // sample the wallpaper, whereas CSS `backdrop-filter` in a transparent
        // window blurs nothing – so the mockup's veil opacities have to
        // compensate for a blur that isn't there, and ours do not.
        return shape
            .fill(.clear)
            .background(backing)
            .overlay(veilLayer)
            .overlay(sheen.opacity(liquid ? 1 : 0))
            .clipShape(shape)
            .overlay(rim(shape))
            .shadow(color: style.shadow, radius: metrics.shadowRadius, x: 0, y: metrics.shadowY)
            // The glass version carries a second, tighter shadow under the
            // first (`0 8px 20px`), which is what keeps the card from floating
            // free of the desktop once the big soft one is this diffuse.
            .shadow(color: liquid ? style.closeShadow : .clear,
                    radius: metrics.closeShadowRadius, x: 0, y: metrics.closeShadowY)
    }

    /// Glass samples the wallpaper; regular is a plain opaque surface.
    ///
    /// `backdrop-filter: none` in the mockup is not a smaller blur — it is *no*
    /// blur, over a solid `#ececec` / `#2c2c2e`. Rendering regular as a weak
    /// blur instead would leave the two materials looking like two strengths of
    /// the same thing, when the point of regular is to be the legible,
    /// wallpaper-independent one.
    @ViewBuilder
    private var backing: some View {
        if liquid {
            // saturate(200%) from the mockup's backdrop-filter. Without it the
            // wallpaper reads washed-out through the glass.
            VisualEffectBacking(material: .underWindowBackground)
                .saturation(2.0)
        } else {
            style.groupFill
        }
    }

    @ViewBuilder
    private var veilLayer: some View {
        if liquid {
            LinearGradient(colors: style.veil, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// The glass version's three `pointer-events: none` layers, in the
    /// mockup's order. They are what separate it from simply "the same card,
    /// more transparent": a lens has direction, and these give it one.
    private var sheen: some View {
        ZStack {
            // 1. Diagonal sweep at 150°, `mix-blend-mode: screen`, opacity .9.
            //    CSS 150deg points down-and-right, so the gradient runs from
            //    upper-left to lower-right with a strong bias downward – hence
            //    the unit points rather than plain .topLeading/.bottomTrailing.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.55), location: 0.00),
                    .init(color: .white.opacity(0.08), location: 0.26),
                    .init(color: .clear, location: 0.50),
                    .init(color: .clear, location: 0.72),
                    .init(color: .white.opacity(0.12), location: 1.00),
                ],
                startPoint: UnitPoint(x: 0.25, y: 0),
                endPoint: UnitPoint(x: 0.75, y: 1)
            )
            .blendMode(.screen)
            .opacity(0.9)

            // 2. Highlight spilling in from just outside the top-left corner:
            //    radial-gradient(120% 80% at 15% -8%, white .6, transparent 42%).
            //
            //    That is an *ellipse* – 120 % of the width across but only 80 %
            //    of the (much shorter) height down, so it is about twice as wide
            //    as it is tall. SwiftUI's radial gradient is circular; drawn as
            //    a circle it washed diagonally across the whole card instead of
            //    staying a corner highlight, which is plainly visible on a dark
            //    capture. So it is drawn round and then squashed to the right
            //    aspect.
            GeometryReader { geo in
                let rx = 0.42 * 1.2 * geo.size.width
                let ry = 0.42 * 0.8 * geo.size.height
                RadialGradient(
                    colors: [.white.opacity(0.6), .clear],
                    center: .center, startRadius: 0, endRadius: rx
                )
                .frame(width: rx * 2, height: rx * 2)
                .scaleEffect(x: 1, y: ry / rx)
                .position(x: 0.15 * geo.size.width, y: -0.08 * geo.size.height)
            }
            .blendMode(.screen)

            // 3. Warm reflex off the bottom inside edge
            //    (`inset 0 -20px 50px rgba(255,255,255,0.3)`).
            LinearGradient(
                colors: [.clear, style.bottomReflex],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .compositingGroup() // the mockup's `isolation: isolate` – keeps
                            // `screen` off whatever is behind the window
        .allowsHitTesting(false)
    }

    /// Rim: the border proper, plus the lit top edge that reads as a lens.
    /// SwiftUI has no inset shadow, so `inset 0 2px 1px white .9` is drawn as a
    /// stroke that fades out below the top edge.
    private func rim(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.strokeBorder(style.border, lineWidth: metrics.borderWidth)
            // Regular has no inset highlights at all — the mockup gives it a
            // plain 1px border and nothing else.
            if let gleam = style.topGleam {
                shape
                    .strokeBorder(
                        LinearGradient(colors: [gleam, .clear], startPoint: .top, endPoint: .center),
                        lineWidth: metrics.borderWidth * 1.4
                    )
            }
            // `inset 0 0 0 1px rgba(255,255,255,0.16)` – a faint uniform inner
            // ring, only in the glass version.
            if liquid {
                shape
                    .inset(by: metrics.borderWidth)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
        }
    }
}

/// Non-heatmap states: loading / no-access / generic failure. Port of
/// `Message` in index.jsx.
private struct MessageCard: View {
    let title: String?
    let body_: String
    var liquid: Bool = true

    /// The approved design covers only the populated grid – loading,
    /// no-access and failure states are not in it (they have been requested).
    /// Until they arrive these keep the card's chrome and a neutral layout;
    /// they are deliberately NOT scaled, so they stay legible at any widget
    /// size and are easy to replace wholesale once the design lands.
    var body: some View {
        let m = HeatmapMetrics(scale: 1, glass: liquid)
        return VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(HeatmapTokens.ink)
            }
            Text(body_)
                .font(.system(size: 12))
                .foregroundStyle(HeatmapTokens.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: HeatmapLayout.messageWidth, alignment: .leading)
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24))
        .background(CardBackground(metrics: m, liquid: liquid))
        .padding(m.shadowPad)
    }
}

// MARK: - Hover state

struct HoverInfo: Equatable {
    let iso: String
    let row: Int
    let col: Int
    let day: DayStats?

    static func == (lhs: HoverInfo, rhs: HoverInfo) -> Bool { lhs.iso == rhs.iso }
}

// MARK: - Main card

struct HeatmapCardView: View {
    @ObservedObject var viewModel: HeatmapViewModel

    @State private var hover: HoverInfo?
    @State private var handleHover = false

    var body: some View {
        switch viewModel.state {
        case .loading:
            MessageCard(title: nil, body_: HeatmapCopy.loadingBody, liquid: viewModel.liquidGlass)
        case .noAccess:
            MessageCard(title: HeatmapCopy.noAccessTitle, body_: HeatmapCopy.noAccessBody, liquid: viewModel.liquidGlass)
        case .failed(let detail):
            MessageCard(title: HeatmapCopy.failedTitle, body_: HeatmapCopy.failedBody(detail), liquid: viewModel.liquidGlass)
        case .data(let days, _):
            grid(days: days)
        }
    }

    private func grid(days: [String: DayStats]) -> some View {
        let m = HeatmapMetrics(scale: viewModel.scale, glass: viewModel.liquidGlass)
        let cells = HeatmapGrid.build()
        let w = viewModel.harmfulWeight
        let thresholds = HeatmapGrid.thresholds(days: days, harmfulWeight: w)
        let ramp = viewModel.accentRamp.count == 5 ? viewModel.accentRamp : Palette.ramp(forAccent: Settings.fallbackAccentDefault).ramp
        let badRamp = viewModel.badRamp.count == 5 ? viewModel.badRamp : Palette.ramp(forAccent: Settings().accentBad).ramp
        let totalSeconds = cells.reduce(0) { $0 + (days[$1.iso]?.t ?? 0) }
        let balance = cells.reduce(0) { $0 + (days[$1.iso]?.weightedScore(w) ?? 0) }
        // "Has the user classified anything at all" – asked of the data rather
        // than of Settings, so the legend always matches the grid it labels.
        let classified = days.values.contains { $0.useful != 0 || $0.destructive != 0 }

        return VStack(alignment: .leading, spacing: 0) {
            header(m: m)
                .padding(.bottom, m.headerBottom)

            ZStack(alignment: .topLeading) {
                heatGrid(cells: cells, days: days, thresholds: thresholds,
                         ramp: ramp, badRamp: badRamp, m: m)
                    .frame(width: m.contentWidth, height: m.gridHeight, alignment: .topLeading)

                // A pinned day (click) wins over hover: the same tooltip, at the
                // same tile, expanded to the full breakdown. Falls back to the
                // hover tooltip (brief top-3) when nothing is pinned.
                let pinnedInfo: HoverInfo? = viewModel.pinnedDay.flatMap { iso in
                    cells.first { $0.iso == iso && !$0.future }
                        .map { HoverInfo(iso: $0.iso, row: $0.row, col: $0.col, day: days[$0.iso]) }
                }
                if let info = pinnedInfo ?? hover {
                    tooltip(for: info, cell: m.tile, gap: m.gap,
                            gridWidth: m.contentWidth, gridHeight: m.gridHeight,
                            pinned: pinnedInfo != nil)
                }
            }
            // Lift the grid+tooltip above the legend and grip: an expanded
            // (pinned) tooltip overflows the grid downward, and without this the
            // legend — a later sibling in the VStack — draws on top of it, so
            // "Harmful … Useful" bled through the card (a user hit this).
            .zIndex(1)

            if viewModel.showLegend {
                legend(ramp: ramp, badRamp: badRamp, totalSeconds: totalSeconds,
                       balance: balance, classified: classified, m: m)
                    .padding(.top, m.legendTop)
            }

            scaleHandle(ramp: ramp, m: m)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, m.handleTop)
        }
        .frame(width: m.contentWidth, alignment: .leading)
        .padding(EdgeInsets(top: m.padTop, leading: m.padSide, bottom: m.padBottom, trailing: m.padSide))
        .background(CardBackground(metrics: m, liquid: viewModel.liquidGlass))
        // Room for the drop shadow, which would otherwise be cut off square
        // by the window edge.
        .padding(m.shadowPad)
        // Tooltip must never spill outside the card: it's laid out inside
        // this ZStack's coordinate space and flipped near the edges (see
        // `tooltip(for:)`), so nothing needs a manual clip here – but keep
        // hit-testing off the glass background itself so drag/hover only
        // fire on their own layers.
    }

    private func header(m: HeatmapMetrics) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(viewModel.strings.today())
                .font(.system(size: m.titleSize, weight: .bold))
                .tracking(m.titleTracking)
                .foregroundStyle(HeatmapTokens.ink)
            Spacer()
        }
        .contentShape(Rectangle())
        .help(viewModel.strings.dragHint)
        // Actual dragging is handled by `AutoSizingHostingView` in
        // DesktopWindow.swift, not here – see that file's doc comment for
        // why a SwiftUI-side NSViewRepresentable drag handle was dropped.
    }

    private func isHovered(_ cell: GridCell) -> Bool {
        hover?.iso == cell.iso && !cell.future
    }

    /// Picks a tile's fill: the good ramp for a positive balance, the bad ramp
    /// for a negative one, and the good ramp's empty step for zero. Kept out of
    /// the view body because the SwiftUI type-checker times out on it inline.
    static func tileColor(
        day: DayStats?,
        thresholds: HeatmapGrid.Thresholds,
        good: [String],
        bad: [String],
        harmfulWeight: Double
    ) -> Color {
        let level = HeatmapGrid.level(score: day.map { $0.weightedScore(harmfulWeight) }, thresholds: thresholds)
        // Step 0 – a day with no balance – is the one tile the dark theme
        // recolours, and it cannot come from the ramp: dark wants a
        // *translucent* white so the card's blur shows through, which no hex
        // in `Palette` can express. Steps 1...4 are identical in both themes.
        guard level.step > 0 else { return HeatmapTokens.neutralTile }
        let ramp = level.sign < 0 ? bad : good
        let index = min(level.step, ramp.count - 1)
        return Color(hex: ramp[index])
    }

    private func heatGrid(
        cells: [GridCell],
        days: [String: DayStats],
        thresholds: HeatmapGrid.Thresholds,
        ramp: [String],
        badRamp: [String],
        m: HeatmapMetrics
    ) -> some View {
        // grid-auto-flow: column – columns are weeks, rows are weekdays.
        HStack(alignment: .top, spacing: m.gap) {
            ForEach(0..<HeatmapGrid.weeks, id: \.self) { col in
                VStack(spacing: m.gap) {
                    ForEach(0..<HeatmapGrid.rows, id: \.self) { row in
                        if let gridCell = cells.first(where: { $0.col == col && $0.row == row }) {
                            let day = days[gridCell.iso]
                            let fill = Self.tileColor(
                                day: gridCell.future ? nil : day,
                                thresholds: thresholds,
                                good: ramp,
                                bad: badRamp,
                                harmfulWeight: viewModel.harmfulWeight
                            )
                            RoundedRectangle(cornerRadius: m.tileRadius, style: .continuous)
                                .fill(fill)
                                // Flat mode keeps the designer's plain hairline
                                // (strokeBorder white .45, 0.5pt). Liquid mode
                                // uses the mockup's inset pair instead –
                                // inset 0 1px 1px white .45 over
                                // inset 0 -1px 1px black .06 – so each tile gets
                                // a lit top edge and a shaded bottom one.
                                .overlay(
                                    RoundedRectangle(cornerRadius: m.tileRadius, style: .continuous)
                                        .strokeBorder(
                                            viewModel.liquidGlass
                                                ? AnyShapeStyle(LinearGradient(
                                                    // Light keeps the value
                                                    // tuned against user
                                                    // screenshots; dark falls
                                                    // back to the mockup's own
                                                    // .45/.06, because 75 %
                                                    // white on 91 tiles over a
                                                    // dark card outlines the
                                                    // whole grid. Unverified on
                                                    // screen – see STATUS.md.
                                                    colors: [Color.themedWhite(light: 0.75, dark: 0.45),
                                                             Color.themed(light: .black.opacity(0.08),
                                                                          dark: .black.opacity(0.06))],
                                                    startPoint: .top, endPoint: .bottom))
                                                // Flat mode is ours, not the
                                                // design's, so dark here is a
                                                // judgement call: the same
                                                // hairline strength the glass
                                                // rims use.
                                                : AnyShapeStyle(Color.themedWhite(light: 0.45, dark: 0.14)),
                                            lineWidth: viewModel.liquidGlass ? max(1, m.scale) : 0.5 * m.scale
                                        )
                                )
                                .opacity(gridCell.future ? 0.35 : 1)
                                .frame(width: m.tile, height: m.tile)
                                // The HTML lifts a hovered tile:
                                // transform: scale(1.18) + 0 4px 12px
                                // rgba(30,25,50,0.25), 0.15s ease. The
                                // designer's SwiftUI dropped hover entirely, so
                                // this comes from the mockup. The shadow is
                                // deliberately neutral ink, not an accent glow:
                                // on the diverging scale a hovered tile can be
                                // on either ramp, and a positive-accent glow
                                // under an orange tile reads as a colour bug.
                                .scaleEffect(isHovered(gridCell) ? 1.18 : 1)
                                .shadow(
                                    color: isHovered(gridCell)
                                        ? HeatmapTokens.tileShadow : .clear,
                                    radius: isHovered(gridCell) ? 6 * m.scale : 0,
                                    x: 0,
                                    y: isHovered(gridCell) ? 4 * m.scale : 0
                                )
                                .zIndex(isHovered(gridCell) ? 1 : 0)
                                .animation(.easeInOut(duration: 0.15), value: hover?.iso)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    guard !gridCell.future else { return }
                                    hover = hovering ? HoverInfo(iso: gridCell.iso, row: row, col: col, day: day) : (hover?.iso == gridCell.iso ? nil : hover)
                                }
                        }
                    }
                }
            }
        }
    }

    /// The design's diverging key: five swatches sampled at balances
    /// [−3, −1, 0, +1, +3], labelled by sign rather than by intensity. Five,
    /// not the full nine steps – the row has to read at a glance from across
    /// a desk, and every extra swatch is another near-identical pale.
    ///
    /// The left-hand figure is the net balance, tinted with the dominant
    /// side's own main colour (`totalColor` in the mockup) so the number and
    /// the tiles that produced it are visibly the same thing.
    ///
    /// One departure from the mockup: until anything is classified the balance
    /// is a permanent, meaningless zero, so that slot shows total tracked time
    /// in plain ink instead. The swatch row is unchanged – it is what explains
    /// the grid, and the grid does not change either.
    private func legend(
        ramp: [String],
        badRamp: [String],
        totalSeconds: Int,
        balance: Int,
        classified: Bool,
        m: HeatmapMetrics
    ) -> some View {
        // The middle swatch is the same themed neutral the zero tiles use, so
        // the key keeps matching the grid it explains in both themes.
        let swatches: [Color] = [
            Color(hex: badRamp[3]), Color(hex: badRamp[1]),
            HeatmapTokens.neutralTile,
            Color(hex: ramp[1]), Color(hex: ramp[3]),
        ]
        let leading = classified
            ? viewModel.strings.balanceTotal(balance)
            : "\(viewModel.strings.duration(totalSeconds)) \(viewModel.strings.totalSuffix)"
        let leadingColor: Color = classified
            ? Color(hex: balance < 0 ? badRamp[3] : ramp[3])
            : HeatmapTokens.inkTotal

        return HStack(spacing: 0) {
            Text(leading)
                .font(.system(size: m.totalSize, weight: .semibold))
                .foregroundStyle(leadingColor)
            Spacer(minLength: m.legendGap)
            HStack(spacing: m.legendGap) {
                Text(viewModel.strings.legendNegative)
                    .padding(.trailing, m.legendLabelGap)
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, colour in
                    RoundedRectangle(cornerRadius: m.swatchRadius, style: .continuous)
                        .fill(colour)
                        .frame(width: m.swatch, height: m.swatch)
                }
                Text(viewModel.strings.legendPositive)
                    .padding(.leading, m.legendLabelGap)
            }
            .font(.system(size: m.legendSize, weight: .medium))
            .foregroundStyle(HeatmapTokens.inkLegend)
            .fixedSize(horizontal: true, vertical: false) // never truncate to "Поль…"
        }
    }

    /// The resize grip: a 64×6 bar centred under the legend. Dragging it
    /// vertically rescales the whole card – the pointer tracking and the
    /// window resize live in `AutoSizingHostingView` (DesktopWindow.swift),
    /// which owns the only `mouseDown` AppKit actually delivers here; this
    /// view is the bar itself and its hover state.
    ///
    /// Hover tint comes from the live ramp rather than the mockup's literal
    /// brand purple: on a mint or blue widget a purple grip is the one thing
    /// on the card that isn't the user's colour.
    private func scaleHandle(ramp: [String], m: HeatmapMetrics) -> some View {
        Capsule(style: .continuous)
            .fill(handleHover ? Color(hex: ramp[3]).opacity(0.6) : HeatmapTokens.handle)
            .frame(width: m.handleWidth, height: m.handleHeight)
            // Hover has to answer over the same box the drag does
            // (`HeatmapLayout.scaleHandleRect`), or the bar lights up on a
            // different area than the one that responds. An overlay rather
            // than padding: it grows the hit box without moving the bar.
            .overlay(
                Color.clear
                    .frame(width: m.handleWidth, height: m.handleHeight + m.handleHitInset * 2)
                    .contentShape(Rectangle())
                    .onHover { handleHover = $0 }
            )
            .animation(.easeInOut(duration: 0.15), value: handleHover)
            .help(viewModel.strings.scaleHint)
    }

    /// Tooltip sits inside the card; flip it left near the right edge and
    /// up near the bottom row so it never overflows the card – same rule
    /// as index.jsx's `tipStyle` (flip based on which half of the grid the
    /// hovered cell is in), adapted to SwiftUI's top-left-anchored layout.
    private func tooltip(for hover: HoverInfo, cell: CGFloat, gap: CGFloat, gridWidth: CGFloat, gridHeight: CGFloat, pinned: Bool) -> some View {
        let weeks = HeatmapGrid.weeks
        let flipX = hover.col > weeks / 2
        let flipY = hover.row > 3
        let step = cell + gap
        // Pinned (expanded) is wider and can be much taller than the brief hover
        // tip, so both the width and the flip-up estimate grow with it.
        let tipWidth: CGFloat = pinned ? 224 : 170
        let tipHeightEstimate: CGFloat = pinned ? 300 : 108

        let x: CGFloat = flipX
            ? CGFloat(hover.col) * step + cell - tipWidth
            : CGFloat(hover.col) * step
        let y: CGFloat = flipY
            ? CGFloat(hover.row) * step - 8 - tipHeightEstimate
            : CGFloat(hover.row) * step + cell + 8

        return TooltipView(hover: hover, strings: viewModel.strings,
                           harmfulWeight: viewModel.harmfulWeight,
                           pinned: pinned, settings: viewModel.settingsSnapshot)
            .frame(width: tipWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Keep it within the card even when the expanded box is tall: clamp
            // the bottom to the grid area plus a little of the legend below it.
            .offset(x: min(max(0, x), max(0, gridWidth - tipWidth)),
                    y: max(0, y))
            .allowsHitTesting(false)
    }
}

private struct TooltipView: View {
    let hover: HoverInfo
    let strings: L10n
    let harmfulWeight: Double
    /// `true` when the day is pinned by a click: show the full breakdown with a
    /// category dot per row instead of the brief top-3.
    var pinned: Bool = false
    var settings: Settings = Settings()

    /// How many breakdown rows a pinned card shows before "+N more"; keeps the
    /// expanded card inside the widget height without needing a scroll view in
    /// a window that never becomes key.
    private static let pinnedRowCap = 12

    private func dotColour(for key: String) -> Color {
        switch settings.effectiveCategory(of: key) {
        case .useful: return Color(hex: settings.accent)
        case .destructive: return Color(hex: settings.accentBad)
        case .neutral: return HeatmapTokens.inkSoft
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(strings.date(iso: hover.iso))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HeatmapTokens.inkSoft)
            Text(hover.day.map { strings.duration($0.t) } ?? strings.noActivity)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HeatmapTokens.ink)

            // Balance line, only once something on this day is classified –
            // otherwise it would read as a permanent, meaningless zero.
            if let day = hover.day, day.useful != 0 || day.destructive != 0 {
                let dayScore = day.weightedScore(harmfulWeight)
                HStack(spacing: 6) {
                    Text(strings.balance(dayScore))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(dayScore < 0 ? HeatmapTokens.bad : HeatmapTokens.good)
                    if day.useful != 0 && day.destructive != 0 {
                        Text("+\(strings.duration(day.useful)) / \u{2212}\(strings.duration(day.destructive))")
                            .font(.system(size: 10))
                            .foregroundStyle(HeatmapTokens.inkSoft)
                    }
                }
                .padding(.bottom, 2)
            }

            if pinned {
                pinnedRows
            } else {
                ForEach(hover.day?.top ?? [], id: \.name) { entry in
                    HStack {
                        Text(entry.name).foregroundStyle(HeatmapTokens.ink)
                        Spacer(minLength: 14)
                        Text(strings.duration(entry.seconds)).foregroundStyle(HeatmapTokens.inkSoft)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // `.regularMaterial` follows the system theme on its own now
                // that no appearance is pinned; only the rim and the shadow
                // need theming.
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.themedWhite(light: 0.7, dark: 0.12), lineWidth: 1))
                .shadow(color: Color.themed(light: .black.opacity(0.18), dark: .black.opacity(0.45)),
                        radius: 14, x: 0, y: 6)
        )
    }

    /// The full breakdown for a pinned day: every app/site with time on it (up
    /// to the cap), a category-coloured dot, name and duration. The full list
    /// is only stored for days written since the feature shipped — an older day
    /// falls back to its top-3 with a one-line note.
    @ViewBuilder
    private var pinnedRows: some View {
        let day = hover.day
        let full = day?.breakdown ?? []
        let entries = full.isEmpty
            ? (day?.top ?? []).map { (key: "", name: $0.name, seconds: $0.seconds) }
            : full.map { (key: $0.key, name: $0.name, seconds: $0.seconds) }
        let shown = Array(entries.prefix(Self.pinnedRowCap))

        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, e in
                HStack(spacing: 7) {
                    Circle().fill(e.key.isEmpty ? HeatmapTokens.inkSoft : dotColour(for: e.key))
                        .frame(width: 6, height: 6)
                    Text(e.name).foregroundStyle(HeatmapTokens.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 10)
                    Text(strings.duration(e.seconds)).foregroundStyle(HeatmapTokens.inkSoft)
                        .monospacedDigit()
                }
                .font(.system(size: 11))
            }
            if entries.count > shown.count {
                Text("+ \(entries.count - shown.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(HeatmapTokens.inkSoft)
                    .padding(.top, 1)
            }
            if full.isEmpty && !(day?.top ?? []).isEmpty {
                Text(strings.dayDetailPartial)
                    .font(.system(size: 9.5))
                    .foregroundStyle(HeatmapTokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

extension Color {
    init(hex: String) {
        var v = hex
        if v.hasPrefix("#") { v.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: v).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

extension Settings {
    static var fallbackAccentDefault: String { Palette.fallbackAccent }
}
