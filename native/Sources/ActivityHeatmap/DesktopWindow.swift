import AppKit
import Combine
import SwiftUI

/// Desktop-level heatmap window. Stage 3: hosts the real widget
/// (`UI/HeatmapView.swift`) instead of stage 1's GLASS/FLAT test cards,
/// sizes itself to the widget's actual content, and drags by its header.
///
/// Window-level and mouse-event facts from ARCHITECTURE.md "Риски" are still
/// load-bearing here and must not regress:
///   - level = desktopIconWindow + 1 – one level *below* this, Finder's
///     full-screen desktop window eats every mouse event first.
///   - window sized to its content, never full-screen – a full-screen
///     window at this level would swallow clicks on empty desktop and
///     block the Finder icons underneath.
///   - acceptsMouseMovedEvents = true – without it hover never fires.
///   - glass is NSVisualEffectView(.behindWindow) (see
///     UI/HeatmapView.swift's `VisualEffectBacking`), never a translucent
///     Color fill.
final class DesktopWindowController: NSWindowController {
    private let margin: CGFloat = 40
    /// Top-left corner of the window, in screen coordinates (Cocoa's y
    /// axis still points up – this is the y of the window's *top* edge,
    /// i.e. `frame.origin.y + frame.height`). Kept as the source of truth
    /// so both dragging and content-driven resizing can reposition the
    /// window while anchoring the same corner, matching the web version's
    /// top/left-anchored CSS.
    private var topLeft: NSPoint
    private let baseTopLeft: NSPoint

    let viewModel: HeatmapViewModel
    private let dragCoordinator = WindowDragCoordinator()
    private var sizeSubscription: AnyCancellable?

    init(viewModel: HeatmapViewModel, onScaleCommit: @escaping (Double) -> Void = { _ in }) {
        self.viewModel = viewModel

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let base = NSPoint(x: screenFrame.minX + margin, y: screenFrame.maxY - margin)
        self.baseTopLeft = base
        let saved = PositionStore.load()
        self.topLeft = NSPoint(x: base.x + CGFloat(saved.x), y: base.y - CGFloat(saved.y))

        let content = HeatmapCardView(viewModel: viewModel)
        let hosting = AutoSizingHostingView(rootView: content, viewModel: viewModel, dragCoordinator: dragCoordinator)
        // Sizing is computed analytically (`HeatmapLayout.size`, below),
        // not by asking SwiftUI/AppKit to self-measure the live view –
        // two self-measurement approaches were tried first and both hit
        // real bugs (see history/STAGE3.md for the full story: a resize feedback
        // loop, then a SwiftUI conditional-view measurement bug). Even
        // with analytical sizing, `NSHostingView`'s default sizingOptions
        // (`.standardBounds`) turned out to independently re-assert its
        // OWN idea of the window's size ~0.3-0.5s after window creation –
        // confirmed live: `window.setFrame` would visibly apply, then
        // silently revert back to the window's original creation frame
        // well after the call returned. `sizingOptions = []` disables
        // that auto-sizing entirely, leaving `applySize` below as the
        // sole author of the window's frame.
        hosting.sizingOptions = []
        let initialSize = HeatmapLayout.size(for: viewModel.state, scale: viewModel.scale,
                                            showLegend: viewModel.showLegend, glass: viewModel.liquidGlass)

        let frame = NSRect(
            x: topLeft.x,
            y: topLeft.y - initialSize.height,
            width: initialSize.width,
            height: initialSize.height
        )

        let window = DesktopCardWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Proven in stage 1 live testing: one level ABOVE the desktop-icon
        // layer is the only level that receives mouse events at all –
        // one level below, Finder's full-screen desktop window (which
        // sits above it) eats them first.
        let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
        window.level = NSWindow.Level(rawValue: Int(iconLevel) + 1)

        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true // without this hover never fires

        hosting.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = hosting

        super.init(window: window)

        dragCoordinator.getTopLeft = { [weak self] in self?.topLeft ?? base }
        dragCoordinator.setTopLeft = { [weak self] point in self?.applyTopLeft(point) }
        dragCoordinator.onDragEnd = { [weak self] point in self?.persist(topLeft: point) }
        dragCoordinator.onReset = { [weak self] in self?.resetPosition() }
        dragCoordinator.onScaleCommit = onScaleCommit

        // Re-measure (analytically) whenever anything that affects card
        // size changes: loading -> data/no-access/failed, a settings
        // change to cellSize/showLegend, etc.
        //
        // `.receive(on:)` is load-bearing, not cosmetic. `@Published` fires its
        // publisher from `willSet`, i.e. BEFORE the property is committed. This
        // sink calls `applySize`, which calls `setFrame(display: true)` – a
        // synchronous display pass. Delivered synchronously, that pass renders
        // the SwiftUI body while `viewModel.state` still holds the OLD value,
        // and SwiftUI then considers the pending invalidation satisfied: the
        // body is never re-evaluated with the new state and the widget stays
        // stuck on "Считаю активность" forever (observed live). Hopping to the
        // next runloop turn lets the property commit first.
        // `liquidGlass` joins the other three because the glass version's
        // shadow is far deeper (`0 40px 90px` against `0 24px 60px`), and the
        // window has to reserve room for it – toggling the setting resizes the
        // window, it is not purely cosmetic.
        sizeSubscription = viewModel.$state
            .combineLatest(viewModel.$scale, viewModel.$showLegend, viewModel.$liquidGlass)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, scale, showLegend, glass in
                self?.applySize(HeatmapLayout.size(for: state, scale: scale,
                                                   showLegend: showLegend, glass: glass))
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless() // do not activate the app on launch
    }


    // MARK: - Geometry

    /// Moves the window to a new top-left corner, keeping its current
    /// size. Used both live during drag and to restore a saved position.
    private func applyTopLeft(_ point: NSPoint) {
        topLeft = point
        guard let window else { return }
        window.setFrameOrigin(NSPoint(x: point.x, y: point.y - window.frame.height))
    }

    /// Re-measures after a content change (loading → grid, or a resized
    /// grid from a new `cellSize`) while anchoring the top-left corner –
    /// mirrors the web version's top/left-anchored CSS, where growing the
    /// card downward never shifts its top edge.
    private func applySize(_ size: CGSize) {
        guard let window else { return }
        guard size.width > 0, size.height > 0 else {
            appLog("DesktopWindowController: ignoring implausible content size \(size)")
            return
        }
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        window.setFrame(newFrame, display: true)
    }

    private func persist(topLeft point: NSPoint) {
        let dx = Int((point.x - baseTopLeft.x).rounded())
        let dy = Int((baseTopLeft.y - point.y).rounded()) // screen/CSS convention: down is positive
        PositionStore.save(.init(x: dx, y: dy))
    }

    private func resetPosition() {
        viewModel.pinnedDay = nil
        applyTopLeft(baseTopLeft)
        PositionStore.save(.init(x: 0, y: 0))
    }

    /// `--open-day-detail`: pins the most recent day with data, so the expanded
    /// in-card detail can be looked at — a real tile click can't be driven from
    /// a shell, same reason `--open-tray` exists.
    func openDayDetailForDiagnostics() {
        guard case let .data(days, _) = viewModel.state else {
            appLog("openDayDetailForDiagnostics: state is not .data yet")
            return
        }
        // The busiest day (most breakdown entries), so the diagnostic exercises
        // the tall-tooltip case that overlaps the legend.
        let cells = HeatmapGrid.build().filter { !$0.future && days[$0.iso] != nil }
        guard let cell = cells.max(by: { (days[$0.iso]?.breakdown.count ?? 0) < (days[$1.iso]?.breakdown.count ?? 0) }) else {
            appLog("openDayDetailForDiagnostics: no day with data found")
            return
        }
        appLog("openDayDetailForDiagnostics: pinning \(cell.iso)")
        viewModel.pinnedDay = cell.iso
    }
}

/// Borderless windows default `canBecomeKey` to `false`, which – combined
/// with a view's default `acceptsFirstMouse(for:)` returning `false` –
/// silently swallows the *first* `mouseDown` a background, non-key window
/// receives (AppKit treats it as an activation click only). This is almost
/// certainly why stage 1's synthetic drag never logged anything even
/// though hover worked fine: `mouseMoved` delivery does not require key
/// status, but `mouseDown` does. Both overrides below are the standard
/// fix for a background utility window that should be draggable without
/// stealing focus first.
final class DesktopCardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Relay between `AutoSizingHostingView` (which cannot reach the owning
/// `NSWindowController` at construction time – see the comment in
/// `DesktopWindowController.init`) and the window's actual geometry.
/// Closures are wired up by the controller right after `super.init`.
final class WindowDragCoordinator {
    var getTopLeft: () -> NSPoint = { .zero }
    var setTopLeft: (NSPoint) -> Void = { _ in }
    var onDragEnd: (NSPoint) -> Void = { _ in }
    var onReset: () -> Void = {}
    /// Called once, on mouse-up, when the resize grip has been dragged.
    /// Persisting live would rewrite settings.json on every mouse-moved event
    /// and echo each write back through `SettingsStore.$settings`; the live
    /// feedback comes from `viewModel.scale` instead.
    var onScaleCommit: (Double) -> Void = { _ in }
}

/// `NSHostingView` that also owns header dragging. Sizing is driven
/// entirely by `HeatmapLayout.size(for:...)` (analytical, in
/// UI/HeatmapView.swift), not by AppKit's `fittingSize`/
/// `intrinsicContentSize` or by a SwiftUI self-measurement trick – see the
/// comment in `DesktopWindowController.init` for why.
///
/// Dragging was originally implemented as a separate `NSViewRepresentable`
/// placed via `.background()` on the SwiftUI header (see git history /
/// history/STAGE3.md) – the idiomatic-looking approach. Live testing showed it
/// never actually received `mouseDown`: a synthetic click at a point
/// confirmed (via a temporary debug override) to be well inside that
/// view's bounds still surfaced at *this* root hosting view's
/// `mouseDown`, never at the embedded subview's. Rather than chase why
/// SwiftUI's NSViewRepresentable-as-background hit-testing didn't route
/// there, dragging is handled directly here – this view is the one AppKit
/// actually calls, confirmed by that same live test – using
/// `HeatmapLayout.headerRect` (the same analytical box-model constants
/// used for sizing) to decide whether a given `mouseDown` started inside
/// the draggable header band.
final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    private let viewModel: HeatmapViewModel
    private let dragCoordinator: WindowDragCoordinator
    private var dragStartMouse: NSPoint?
    private var dragStartTopLeft: NSPoint?
    /// Screen y and the scale the card had when the resize grip was grabbed.
    /// Non-nil for exactly as long as a resize drag is in flight.
    private var scaleStartMouseY: CGFloat?
    private var scaleStartValue: CGFloat?
    private var cursorTrackingAreas: [NSTrackingArea] = []

    init(rootView: Content, viewModel: HeatmapViewModel, dragCoordinator: WindowDragCoordinator) {
        self.viewModel = viewModel
        self.dragCoordinator = dragCoordinator
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    @MainActor required dynamic init(rootView: Content) {
        fatalError("use init(rootView:viewModel:dragCoordinator:)")
    }

    // Without this, a click anywhere on the card still gets eaten as an
    // activation-only click on a background, non-key window – see
    // `DesktopCardWindow`'s doc comment for the full explanation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scaleHandleRect: CGRect {
        HeatmapLayout.scaleHandleRect(
            for: viewModel.state,
            scale: viewModel.scale,
            showLegend: viewModel.showLegend,
            glass: viewModel.liquidGlass
        )
    }

    private var cardRect: CGRect {
        HeatmapLayout.cardRect(
            for: viewModel.state,
            scale: viewModel.scale,
            showLegend: viewModel.showLegend,
            glass: viewModel.liquidGlass
        )
    }

    /// The cursor for a *resting* pointer at `local`: resize over the grip, the
    /// plain arrow everywhere else. The card body is NOT an open hand — per the
    /// user's ask, the hand appears only while a drag is actually in progress
    /// (`closedHand`, set from the drag handlers) and reverts to the arrow the
    /// moment the button is released.
    private func restingCursor(at local: NSPoint) -> NSCursor {
        scaleHandleRect.contains(local) ? .resizeUpDown : .arrow
    }

    private var isDraggingCard: Bool { dragStartMouse != nil }

    /// Cursor is driven by `cursorUpdate` + tracking areas, NOT `mouseMoved`.
    /// `mouseMoved` is delivered only to the *key* window, and this widget
    /// deliberately never becomes key (desktop level, `acceptsFirstMouse` so a
    /// click doesn't steal focus) — so a `mouseMoved`-based cursor never fired
    /// on hover, and whatever was last set stayed frozen on the pointer (the
    /// grab hand "stuck" after a drag). Tracking areas with `.cursorUpdate`
    /// fire regardless of key/active status, which is the mechanism that works
    /// here.
    ///
    /// TWO nested areas — the whole card, then the grip on top of it — so that
    /// `cursorUpdate` re-fires when the pointer crosses the grip's edge. A
    /// single area only fires on entering the card, never on moving body↔grip
    /// within it, which is the other half of why the cursor got stuck.
    /// Re-armed on every `updateTrackingAreas` (AppKit calls it when the view's
    /// frame changes — i.e. every resize).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in cursorTrackingAreas { removeTrackingArea(area) }
        cursorTrackingAreas.removeAll()

        let card = cardRect
        guard !card.isEmpty else { return }
        // Card first (also carries enter/exit so the arrow comes back on the
        // way out), grip second so it wins where they overlap.
        for (rect, options) in [
            (card, NSTrackingArea.Options([.cursorUpdate, .mouseEnteredAndExited, .activeAlways])),
            (scaleHandleRect, NSTrackingArea.Options([.cursorUpdate, .activeAlways])),
        ] where !rect.isEmpty {
            let area = NSTrackingArea(rect: rect, options: options, owner: self)
            addTrackingArea(area)
            cursorTrackingAreas.append(area)
        }
    }

    /// The single source of truth for the pointer's shape. Everything else just
    /// asks AppKit to invalidate cursor rects so this runs again.
    override func cursorUpdate(with event: NSEvent) {
        if isDraggingCard { NSCursor.closedHand.set(); return }
        if scaleStartMouseY != nil { NSCursor.resizeUpDown.set(); return }
        restingCursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Mid-gesture the pointer is routinely dragged outside the card; keep
        // the gesture's cursor until it actually ends.
        guard !isDraggingCard, scaleStartMouseY == nil else { return }
        restoreCursor()
    }

    /// Force `cursorUpdate` to run now, without waiting for the pointer to
    /// cross a tracking boundary — used the instant a drag ends, so the grab
    /// hand relaxes back to the resting cursor immediately instead of freezing.
    private func refreshCursorNow() {
        window?.invalidateCursorRects(for: self)
        restingCursor(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)).set()
    }

    /// Puts the default arrow back. Safe to call when the pointer has already
    /// moved over another window: that window sets its own cursor as soon as
    /// it sees the mouse, and the arrow is the correct fallback everywhere else.
    private func restoreCursor() {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Grip first: it sits inside the card's bottom padding, well clear of
        // the header band, but checking it first keeps the two unambiguous.
        if scaleHandleRect.contains(local) {
            appLog("scale: mouseDown local=\(local) scale=\(viewModel.scale)")
            scaleStartMouseY = NSEvent.mouseLocation.y
            scaleStartValue = viewModel.scale
            return
        }
        // Move on a drag anywhere on the card (the grip above already claimed
        // the resize zone). Was header-only, which stranded the widget once its
        // top edge — and with it the only draggable band — scrolled off the top
        // of the screen: nothing left on screen to grab, and the double-click
        // reset lived there too. The whole card now moves, so any visible part
        // brings it back, and a double-click anywhere resets its position.
        guard cardRect.contains(local) else {
            super.mouseDown(with: event)
            return
        }
        appLog("drag: mouseDown clickCount=\(event.clickCount) local=\(local)")
        dragStartMouse = NSEvent.mouseLocation
        dragStartTopLeft = dragCoordinator.getTopLeft()
        NSCursor.closedHand.set() // grabbed
    }

    override func mouseDragged(with event: NSEvent) {
        if let startY = scaleStartMouseY, let base = scaleStartValue {
            // Pull down to grow, as in the mockup. Its `ev.clientY - startY` is
            // in web coordinates, where y grows downward; Cocoa's screen y grows
            // upward, hence the subtraction the other way round.
            let travelled = startY - NSEvent.mouseLocation.y
            let raw = Double(base + travelled / HeatmapMetrics.scaleDragTravel)
            viewModel.scale = CGFloat(min(max(raw, HeatmapMetrics.scaleRange.lowerBound),
                                          HeatmapMetrics.scaleRange.upperBound))
            return
        }
        guard let startMouse = dragStartMouse, let startTopLeft = dragStartTopLeft else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - startMouse.x, y: current.y - startMouse.y)
        dragCoordinator.setTopLeft(NSPoint(x: startTopLeft.x + delta.x, y: startTopLeft.y + delta.y))
        NSCursor.closedHand.set() // hold the grabbed cursor through the drag
    }

    override func mouseUp(with event: NSEvent) {
        if scaleStartMouseY != nil {
            scaleStartMouseY = nil
            scaleStartValue = nil
            appLog("scale: mouseUp scale=\(viewModel.scale)")
            dragCoordinator.onScaleCommit(Double(viewModel.scale))
            // Both gestures moved the card out from under the pointer, so settle
            // the cursor to whatever it is actually over now.
            refreshCursorNow()
            return
        }
        guard dragStartMouse != nil else {
            super.mouseUp(with: event)
            return
        }
        defer {
            dragStartMouse = nil
            dragStartTopLeft = nil
            // Released: relax the grabbed hand back to the resting cursor at
            // once, without waiting to cross a tracking boundary.
            refreshCursorNow()
        }
        appLog("drag: mouseUp clickCount=\(event.clickCount)")
        if event.clickCount == 2 {
            dragCoordinator.onReset()
            return
        }
        // A click that never moved (within a few points) is not a drag. On a
        // tile it pins/unpins that day's detail (the tooltip expands in place);
        // on empty card area it clears any pin. Moving past the threshold is a
        // reposition and does neither.
        if let startMouse = dragStartMouse {
            let moved = hypot(NSEvent.mouseLocation.x - startMouse.x,
                              NSEvent.mouseLocation.y - startMouse.y)
            if moved <= 4 {
                let iso = dayForTile(at: convert(event.locationInWindow, from: nil))
                // Toggle: clicking the pinned day again (or empty area) closes it.
                viewModel.pinnedDay = (iso != nil && iso != viewModel.pinnedDay) ? iso : nil
                return
            }
        }
        dragCoordinator.onDragEnd(dragCoordinator.getTopLeft())
    }

    /// The ISO day of the tile under `local`, or nil if the point is in a gap,
    /// off the grid, or on a future cell (those aren't clickable).
    private func dayForTile(at local: NSPoint) -> String? {
        guard let (col, row) = HeatmapLayout.tile(at: local, for: viewModel.state,
                                                  scale: viewModel.scale, glass: viewModel.liquidGlass)
        else { return nil }
        let cell = HeatmapGrid.build().first { $0.col == col && $0.row == row }
        guard let cell, !cell.future else { return nil }
        return cell.iso
    }

}
