import CoreGraphics
import Foundation

/// `HeatmapLayout` computes the card's size analytically instead of measuring
/// the live SwiftUI view (see its doc comment for why), which means every
/// constant in it is kept in sync with `HeatmapCardView` *by hand*. Nothing
/// catches a drift there at compile time, and the widget cannot be
/// screenshotted on this machine (STATUS.md, "Ограничение окружения") – so the
/// relationships that must hold are asserted here instead.
enum HeatmapLayoutTests {
    private static let sample: HeatmapState = .data(
        days: ["2026-07-20": DayStats(t: 3600, top: [], useful: 3600, destructive: 0)],
        tracked: true
    )

    static func run() {
        todayMarker()
        SelfTest.suite("HeatmapLayout") {
            // Both materials, because the glass version changes real geometry:
            // corner radius, rim width and — the one that reaches the window —
            // a much deeper shadow, so every rect below shifts with it.
            for glass in [true, false] {
                handleRectStates(glass: glass)
                handleRectGeometry(glass: glass)
                legendAffectsBoth(glass: glass)
                scaleIsProportional(glass: glass)
            }
            scaleRangeIsUsable()
            glassChangesOnlyChrome()
            tileHitTesting()
        }
    }

    /// A click has to map back to the tile it landed on. `tileRect` (used to
    /// anchor the day-detail panel) and `tile(at:)` (used to turn a click into
    /// a day) must agree, or the panel opens for the wrong day or none.
    private static func tileHitTesting() {
        for glass in [true, false] {
            for (col, row) in [(0, 0), (6, 3), (HeatmapGrid.weeks - 1, HeatmapGrid.rows - 1)] {
                let rect = HeatmapLayout.tileRect(col: col, row: row, for: sample, scale: 1, glass: glass)
                SelfTest.expect(!rect.isEmpty, "tile (\(col),\(row)) has a rect")
                // The centre of a tile maps back to that tile.
                let hit = HeatmapLayout.tile(at: CGPoint(x: rect.midX, y: rect.midY),
                                             for: sample, scale: 1, glass: glass)
                SelfTest.expectEqual(hit?.col, col, "centre maps back to col \(col)")
                SelfTest.expectEqual(hit?.row, row, "centre maps back to row \(row)")
            }
            // A point in the gap between tiles is not a hit.
            let m = HeatmapMetrics(scale: 1, glass: glass)
            let first = HeatmapLayout.tileRect(col: 0, row: 0, for: sample, scale: 1, glass: glass)
            let gap = HeatmapLayout.tile(at: CGPoint(x: first.maxX + m.gap / 2, y: first.midY),
                                         for: sample, scale: 1, glass: glass)
            SelfTest.expect(gap?.col != 0, "a point in the gap after col 0 is not col 0")
        }
    }

    /// Only the populated grid has a resize grip. The message cards have no
    /// header either – both are non-interactive by design.
    private static func handleRectStates(glass: Bool) {
        for state in [HeatmapState.loading, .noAccess, .failed("boom")] {
            SelfTest.expect(
                HeatmapLayout.scaleHandleRect(for: state, scale: 1, showLegend: true, glass: glass).isEmpty,
                "no resize grip outside the .data state"
            )
        }
        SelfTest.expect(
            !HeatmapLayout.scaleHandleRect(for: sample, scale: 1, showLegend: true, glass: glass).isEmpty,
            ".data state has a resize grip"
        )
    }

    /// The grip must land where the view draws it: centred on the card, inside
    /// the bottom padding, clear of the draggable header band. If the two ever
    /// disagree the bar lights up in one place and responds in another.
    private static func handleRectGeometry(glass: Bool) {
        let m = HeatmapMetrics(scale: 1, glass: glass)
        let card = HeatmapLayout.cardRect(for: sample, scale: 1, showLegend: true, glass: glass)
        let grip = HeatmapLayout.scaleHandleRect(for: sample, scale: 1, showLegend: true, glass: glass)

        SelfTest.expectClose(Double(grip.midX), Double(card.midX), tol: 0.5,
                             label: "grip is centred on the card")
        SelfTest.expectEqual(grip.width, m.handleWidth, "grip is as wide as it is drawn")
        SelfTest.expect(card.contains(grip), "grip stays inside the card")
        SelfTest.expect(grip.maxY <= card.maxY, "grip does not spill past the bottom edge")

        // The hit box is padded vertically for grabbability; the drawn bar is
        // the design's 6pt and sits in the middle of it.
        SelfTest.expectEqual(grip.height, m.handleHeight + m.handleHitInset * 2,
                             "grip hit box is padded on both sides")

        // The move region is now the whole card, and it must contain both the
        // resize grip (checked first, so it wins) and the header band — a drag
        // anywhere else on the card repositions the widget.
        let header = HeatmapLayout.headerRect(for: sample, scale: 1, glass: glass)
        SelfTest.expect(card.contains(header), "header sits inside the draggable card")
        SelfTest.expect(card.contains(grip), "grip sits inside the draggable card")
    }

    /// Hiding the legend has to move the grip and shrink the window by exactly
    /// the same amount – they are computed from the same term.
    private static func legendAffectsBoth(glass: Bool) {
        let withLegend = HeatmapLayout.size(for: sample, scale: 1, showLegend: true, glass: glass)
        let without = HeatmapLayout.size(for: sample, scale: 1, showLegend: false, glass: glass)
        let gripWith = HeatmapLayout.scaleHandleRect(for: sample, scale: 1, showLegend: true, glass: glass)
        let gripWithout = HeatmapLayout.scaleHandleRect(for: sample, scale: 1, showLegend: false, glass: glass)

        SelfTest.expectEqual(withLegend.width, without.width, "legend does not change card width")
        SelfTest.expect(without.height < withLegend.height, "hiding the legend shortens the card")
        SelfTest.expectClose(Double(withLegend.height - without.height),
                             Double(gripWith.minY - gripWithout.minY),
                             tol: 0.5,
                             label: "grip rises by exactly the legend's height")
    }

    /// One proportional scale drives the whole card – the resize grip would
    /// otherwise drift away from the bar it is supposed to be under.
    private static func scaleIsProportional(glass: Bool) {
        let one = HeatmapLayout.size(for: sample, scale: 1, showLegend: true, glass: glass)
        let half = HeatmapLayout.size(for: sample, scale: 0.5, showLegend: true, glass: glass)
        // Text does not scale perfectly linearly (font metrics round), so this
        // is a loose check that both axes moved together, not a pixel identity.
        SelfTest.expectClose(Double(half.width / one.width), 0.5, tol: 0.01, label: "width halves")
        SelfTest.expectClose(Double(half.height / one.height), 0.5, tol: 0.03, label: "height halves")

        let grip = HeatmapLayout.scaleHandleRect(for: sample, scale: 0.5, showLegend: true, glass: glass)
        SelfTest.expectEqual(grip.width, HeatmapMetrics(scale: 0.5, glass: glass).handleWidth,
                             "grip scales with the card")
    }

    private static func scaleRangeIsUsable() {
        let range = HeatmapMetrics.scaleRange
        SelfTest.expect(range.contains(Settings().scale), "default scale is reachable by the grip")
        SelfTest.expect(range.lowerBound > 0, "scale range is positive")
        // A full drag from one end to the other must be a comfortable gesture,
        // not a screen-height sweep.
        let travel = CGFloat(range.upperBound - range.lowerBound) * HeatmapMetrics.scaleDragTravel
        SelfTest.expect(travel > 50 && travel < 600, "end-to-end drag travel is \(travel)pt")
    }

    /// The glass version is a *material*. It may grow the window (its shadow is
    /// deeper and the margin has to clear it) but it must not change the card's
    /// own layout — same content width, same grid, same distance from the card's
    /// top edge down to the grip.
    private static func glassChangesOnlyChrome() {
        let g = HeatmapMetrics(scale: 1, glass: true)
        let f = HeatmapMetrics(scale: 1, glass: false)

        SelfTest.expectEqual(g.cardWidth, f.cardWidth, "card width is material-independent")
        SelfTest.expectEqual(g.gridHeight, f.gridHeight, "grid height is material-independent")
        SelfTest.expectEqual(g.contentWidth, f.contentWidth, "content width is material-independent")
        // The HIG pass unified the corner radius: both materials now use
        // `KiRadius.widget` (28), where glass used to be 42 against 34.
        SelfTest.expectEqual(g.cardRadius, f.cardRadius, "radius is material-independent")
        SelfTest.expectEqual(g.cardRadius, KiRadius.widget, "widget uses the HIG radius")
        SelfTest.expect(g.shadowPad > f.shadowPad, "glass reserves more room for its shadow")

        // The margin must actually clear the shadow it exists for, or the card
        // gets a square-cornered smudge at the window edge.
        for m in [g, f] {
            SelfTest.expect(m.shadowPad > m.shadowY + m.shadowRadius,
                            "shadow margin \(m.shadowPad) clears \(m.shadowY) + \(m.shadowRadius)")
        }

        let glassSize = HeatmapLayout.size(for: sample, scale: 1, showLegend: true, glass: true)
        let flatSize = HeatmapLayout.size(for: sample, scale: 1, showLegend: true, glass: false)
        SelfTest.expectClose(Double(glassSize.width - flatSize.width),
                             Double((g.shadowPad - f.shadowPad) * 2), tol: 0.5,
                             label: "window grows by exactly the extra margin")

        // Card-relative geometry is identical once the margin is subtracted.
        let gGrip = HeatmapLayout.scaleHandleRect(for: sample, scale: 1, showLegend: true, glass: true)
        let fGrip = HeatmapLayout.scaleHandleRect(for: sample, scale: 1, showLegend: true, glass: false)
        SelfTest.expectClose(Double(gGrip.minY - g.shadowPad), Double(fGrip.minY - f.shadowPad),
                             tol: 0.5, label: "grip sits at the same place on the card")
    }

    /// Exactly one cell is today's and it is never treated as future. Guards
    /// the flag that carries today's outline – without it a day in progress is
    /// indistinguishable from an empty one, which is how it was reported: the
    /// first coloured step differs from the empty step by ~9% in RGB, and over
    /// blurred wallpaper that reads as "today is not counted".
    private static func todayMarker() {
        SelfTest.suite("Grid/today") {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!

            let fmt = DateFormatter()
            fmt.calendar = cal
            fmt.timeZone = cal.timeZone
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"

            // A Tuesday, so part of the current week is still ahead.
            let tuesday = Date(timeIntervalSince1970: 1_784_000_000)
            let cells = HeatmapGrid.build(today: tuesday, calendar: cal)

            let marked = cells.filter(\.isToday)
            SelfTest.expectEqual(marked.count, 1, "exactly one cell is today")
            SelfTest.expect(marked.first?.future == false, "today is never a future cell")
            SelfTest.expectEqual(marked.first?.iso, fmt.string(from: tuesday),
                                 "the marked cell is actually today")
            SelfTest.expect(cells.filter(\.future).allSatisfy { $0.iso > (marked.first?.iso ?? "") },
                            "future cells all come after today")

            // Sunday closes the week: nothing ahead, still exactly one today.
            let sunday = cal.date(byAdding: .day, value: 5, to: tuesday)!
            let sundayCells = HeatmapGrid.build(today: sunday, calendar: cal)
            SelfTest.expectEqual(sundayCells.filter(\.future).count, 0,
                                 "on Sunday no cell is in the future")
            SelfTest.expectEqual(sundayCells.filter(\.isToday).count, 1,
                                 "Sunday still marks exactly one today")
        }
    }
}
