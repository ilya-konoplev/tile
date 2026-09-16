import AppKit
import Combine
import SwiftUI

/// Menu bar icon and the panel it drops. The widget toggle is driven by
/// `SettingsStore` – the same source of truth the settings window reads and
/// writes – rather than private local state, so the two can never disagree
/// about whether the widget is on.
///
/// The drop-down is the design's own glass panel (`UI/TrayPanel.swift`), shown
/// in an `NSPopover`, not an `NSMenu`: the mockup's row carries a two-line
/// label and a real switch, neither of which an `NSMenu` can render.
///
/// One consequence of leaving `NSMenu` behind: the ⌘, and ⌘Q equivalents that
/// used to hang off the menu items are gone. The app is `LSUIElement`, so it
/// has no app menu to host them either – the panel is the only surface, which
/// is exactly what the design shows.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settingsStore: SettingsStore
    private var settingsWindowController: SettingsWindowController?
    private let popover = NSPopover()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarController.brandIcon()
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // The panel is a light design, like the rest of the app's glass; left
        // to adapt it would go dark and fight the white gradient inside.
        // Appearance is set per-show in `showPanel`, not pinned here – it used
        // to be forced to `.aqua` while the design was light-only.
        let hosting = NSHostingController(
            rootView: TrayPanelView(
                store: settingsStore,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { [weak self] in self?.quit() }
            )
        )
        // Load-bearing. Without it `NSHostingController` reports AppKit's
        // default 500×500 until SwiftUI has laid out, and `NSPopover` anchors
        // itself using *that* size – then the panel shrinks to its real 264pt
        // and the arrow is left ~150pt below the menu bar, hanging in mid
        // screen (measured: panel top at Cocoa y=769 against a button bottom of
        // y=923). `.preferredContentSize` keeps the controller's size in step
        // with the SwiftUI content, so the popover anchors against the truth.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    /// The design's "1a" logo, simplified to a single tile (see
    /// `design/App Logo.dc.html`'s "В МАСШТАБЕ" row: the full 3x3 grid
    /// is illegible at 18pt, so the mockup collapses it to one rounded
    /// square with a center dot). Loaded as a single high-resolution
    /// (54px = 3x) bitmap with its display size pinned to 18x18pt – AppKit
    /// downsamples that one bitmap for 1x/2x displays, so a single asset
    /// covers every scale without needing separate @1x/@2x/@3x files.
    /// Colored deliberately, not a template image: the mockup's menu-bar
    /// face has its own purple fill rather than a monochrome silhouette,
    /// so it doesn't need to adapt to the menu bar's light/dark tint.
    private static func brandIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            appLog("MenuBar: MenuBarIcon.png not found in bundle, falling back to SF Symbol")
            return NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "ActivityHeatmap")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        // Without an explicit activate the transient popover can open behind
        // whatever is frontmost and dismiss itself on the next click – the app
        // runs as an accessory and is never otherwise active.
        NSApp.activate(ignoringOtherApps: true)
        showPanel(from: button)
    }

    private func showPanel(from button: NSStatusBarButton) {
        // Leaving `popover.appearance` nil does NOT make the panel follow the
        // app: an `NSPopover` inherits from its positioning view, which here
        // lives in the system status bar window, not in our hierarchy. Observed
        // – with the app forced to dark, every other surface turned dark and
        // this panel stayed light. Bind it to the app's effective appearance so
        // it tracks the system deliberately rather than by coincidence.
        popover.appearance = NSApp.effectiveAppearance
        // `.minY`, not `.maxY`. AppKit reads the edge in the button's own
        // unflipped space, where maxY is its *top* – i.e. "put the panel above
        // the menu bar". There is no room there, so AppKit fell back to placing
        // it below but well clear of the bar, and the panel hung in mid-screen
        // instead of under its icon (seen in a user screenshot). minY is the
        // bottom edge, which is where a menu bar drop-down belongs.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appLog("MenuBar: panel shown, button frame=\(button.window?.frame ?? .zero)")
    }

    /// Entry point for the `--open-tray` diagnostic flag. The panel only ever
    /// appears on a click, and a click on a menu bar extra cannot be driven
    /// from a shell – so without this there is no way to measure or capture it.
    func openPanelForDiagnostics() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        showPanel(from: button)
    }

    /// Entry point for the `--open-settings` diagnostic flag (see main.swift).
    func openSettingsForDiagnostics(screen: SettingsScreen) {
        openSettings(screen: screen)
        // Float it. The app is an accessory, so `NSApp.activate` does not keep
        // it above a normal app's window for long, and a capture of the region
        // then shows whatever is on top instead — which defeats the only
        // purpose this entry point has. Diagnostics-only: `openSettings` for
        // real users leaves the level alone.
        settingsWindowController?.window?.level = .floating
    }

    private func openSettings(screen: SettingsScreen = .main) {
        popover.performClose(nil)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: settingsStore, initialScreen: screen)
        }
        // The app runs as an accessory (no Dock icon) – without an explicit
        // activate, a freshly-created window can open behind whatever else is
        // frontmost.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
    }

    private func quit() {
        appLog("MenuBar: quit requested")
        NSApp.terminate(nil)
    }
}
