import AppKit
import Combine
import SwiftUI

/// Entry point. Wires the NSApplicationDelegate lifecycle to the three
/// pieces that make up the app: the desktop window (`DesktopWindow.swift`),
/// the menu bar item (`MenuBar.swift`) and the data pipeline
/// (`Data/Store.swift`), plus the settings that connect them.
///
/// Startup also writes a few diagnostics to a log file rather than stdout:
/// a bundled `.app` launched from Finder has no terminal attached, so the
/// log is the only way to see what happened after the fact.

let logURL = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ActivityHeatmap/activity.log")

func appLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    print(line, terminator: "")
    let dir = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var desktopWindowController: DesktopWindowController?
    var menuBarController: MenuBarController?
    let store = Store()
    let viewModel = HeatmapViewModel()
    let settingsStore = SettingsStore()
    private var cancellables = Set<AnyCancellable>()
    /// Diagnostic override for `Settings.liquidGlass`; never persisted.
    private var forcedGlass: Bool?
    /// True while `--force-theme` is in effect, so `applyToWidget` leaves the
    /// appearance alone.
    private var forcedAppearance = false
    /// The hourly refresh timer and the App-Nap suppression token. Both are
    /// held for the app's whole life; see `startRefreshLoop`.
    private var refreshTimer: Timer?
    private var refreshActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement handles the "no Dock icon" behavior via Info.plist,
        // but set the activation policy explicitly too so `swift run`
        // (which has no Info.plist) behaves the same way during dev.
        NSApp.setActivationPolicy(.accessory)

        // `--force-theme dark|light` overrides the appearance for THIS PROCESS
        // only. The theme normally follows the system, and the alternative way
        // to see the other one is to flip the user's own system-wide
        // appearance – which is not something a build script should do. Affects
        // nothing but rendering.
        if let i = CommandLine.arguments.firstIndex(of: "--force-theme"),
           i + 1 < CommandLine.arguments.count {
            let name: NSAppearance.Name = CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: name)
            forcedAppearance = true
            appLog("forced appearance: \(name.rawValue)")
        }

        appLog("=== ActivityHeatmap launch ===")
        appLog("CGWindowLevelForKey(.desktopIconWindow) = \(CGWindowLevelForKey(.desktopIconWindow))")
        appLog("CGWindowLevelForKey(.desktopWindow) = \(CGWindowLevelForKey(.desktopWindow))")

        FullDiskAccessProbe.run()

        // `--force-glass on|off` renders the other material without writing to
        // the user's settings.json. Same reason as `--force-theme`: both
        // branches have to be observable, and the only other way to see this
        // one is to flip a real setting.
        if let i = CommandLine.arguments.firstIndex(of: "--force-glass"),
           i + 1 < CommandLine.arguments.count {
            forcedGlass = CommandLine.arguments[i + 1] == "on"
            KiDiagnostics.forcedGlass = forcedGlass
            appLog("forced glass: \(forcedGlass!)")
        }

        applyToWidget(settingsStore.settings)

        // The widget's own resize grip writes back into the same setting the
        // settings-window slider drives, so the two stay one value.
        desktopWindowController = DesktopWindowController(viewModel: viewModel) { [weak self] scale in
            self?.settingsStore.setScale(scale)
        }
        if settingsStore.settings.widgetEnabled {
            desktopWindowController?.showWindow(nil)
        }

        menuBarController = MenuBarController(settingsStore: settingsStore)

        // Diagnostic, same family as `--self-test` / `--check-fda`: opens the
        // settings window straight away. The desktop widget cannot be captured
        // on this machine (STATUS.md, "Ограничение окружения"), but a normal
        // framed window can – this is the only way to actually *look* at the
        // settings screens instead of reasoning about them.
        if CommandLine.arguments.contains("--open-settings") {
            let screen: SettingsScreen = CommandLine.arguments.contains("--apps") ? .appsSites : .main
            menuBarController?.openSettingsForDiagnostics(screen: screen)
        }
        // `--flip-glass` toggles the material 5s after launch through
        // `SettingsStore`, i.e. down the exact code path the segmented control
        // uses. It exists because "does clicking it actually change anything"
        // cannot be answered by `--force-glass` — that flag bypasses the
        // setting entirely, which is how a frozen environment went unnoticed.
        if CommandLine.arguments.contains("--flip-glass") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                let next = !self.settingsStore.settings.liquidGlass
                appLog("flip-glass: liquidGlass -> \(next)")
                self.settingsStore.setLiquidGlass(next)
            }
        }
        if CommandLine.arguments.contains("--open-day-detail") {
            // Long delay: the first aggregation reads ~20k knowledgeC rows on a
            // background queue, so `.data` isn't ready for a few seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.desktopWindowController?.openDayDetailForDiagnostics()
            }
        }
        if CommandLine.arguments.contains("--open-tray") {
            // The status item needs a layout pass before its button has a real
            // screen position to anchor the panel to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.menuBarController?.openPanelForDiagnostics()
            }
        }

        // Settings window and tray toggle both mutate `settingsStore`;
        // this is the one place that turns those mutations into visible
        // effects on the live widget (stage-4 brief item 3: accent
        // rebuilds the ramp, cellSize resizes, widgetEnabled shows/hides
        // the desktop window).
        settingsStore.$settings
            .sink { [weak self] settings in self?.applyToWidget(settings) }
            .store(in: &cancellables)

        // Apps/sites filter changes should be reflected without waiting
        // an hour – kick an immediate re-aggregation. (Cosmetic changes
        // like accent/cellSize/widgetEnabled do NOT trigger this; they
        // only need the Combine sink above.)
        settingsStore.onFilterSettingsChanged = { [weak self] in
            guard let self else { return }
            self.refresh(settings: self.settingsStore.settings)
        }

        refresh(settings: settingsStore.settings)
        startRefreshLoop()
    }

    // MARK: - Refresh loop

    /// Hourly refresh, made resilient to the two ways it used to silently die:
    ///
    ///  1. **App Nap froze the timer.** As an `LSUIElement` accessory with no
    ///     Dock icon, the app is exactly what macOS suspends when it looks idle
    ///     — and a plain `Timer` on the main runloop stops firing entirely, not
    ///     late. Observed live: 13 h with the process alive, FDA granted, and
    ///     not one refresh logged. `beginActivity(.background)` held for the
    ///     app's whole life tells the system this process has real background
    ///     work and must keep getting time.
    ///
    ///  2. **The timer wrote the file but never the view.** `Store.startTimer`
    ///     called `Store.refresh` directly, which updates `activity.json` but
    ///     not `viewModel.state`, so the on-screen tiles only ever changed at
    ///     launch or on a filter edit. The loop now goes through the same
    ///     `refresh(settings:)` the launch path uses, which updates both.
    ///
    /// Plus a wake handler: after a long sleep the next tick could be up to an
    /// hour out, so a real system wake refreshes immediately rather than
    /// leaving today's tile empty until the timer next comes round.
    private func startRefreshLoop() {
        // Held, not discarded: the token only suppresses App Nap while it is
        // alive. `.idleSystemSleepDisabled` is deliberately NOT set — we do not
        // keep the Mac awake, we only ask not to be frozen while it is.
        refreshActivity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .suddenTerminationDisabled],
            reason: "Hourly activity aggregation"
        )

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            appLog("refresh loop: hourly tick")
            self.refresh(settings: self.settingsStore.settings)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            appLog("refresh loop: system wake, refreshing")
            self.refresh(settings: self.settingsStore.settings)
        }
    }

    /// Applies the cosmetic/visibility half of `Settings` to the already-
    /// live widget. Safe to call before `desktopWindowController` exists
    /// (startup path) – the visibility half no-ops until it does.
    private func applyToWidget(_ settings: Settings) {
        let theme = Palette.ramp(forAccent: settings.accent)
        viewModel.accentRamp = theme.ramp
        viewModel.badRamp = Palette.ramp(forAccent: settings.accentBad).ramp
        // Keep the rendered copy and the copy `HeatmapLayout` measures on the
        // same language, or the window will be sized for the wrong strings.
        let strings = L10n(settings.language)
        HeatmapCopy.strings = strings
        viewModel.strings = strings
        viewModel.scale = CGFloat(settings.scale)
        viewModel.showLegend = settings.showLegend
        viewModel.liquidGlass = forcedGlass ?? settings.liquidGlass
        // Weight is a pure display knob (applied to the score at render), so
        // updating the published value re-colours the grid without touching
        // the stored seconds — no re-aggregation needed.
        viewModel.harmfulWeight = settings.clampedHarmfulWeight
        viewModel.settingsSnapshot = settings
        // Appearance override. `nil` (system) clears the app-level appearance
        // and lets every window follow macOS again, which is the default.
        // Skipped entirely while `--force-theme` is driving, or the diagnostic
        // flag would be overwritten by whatever is in settings.json.
        if !forcedAppearance {
            NSApp.appearance = settings.appearance.nsAppearance
        }

        guard let controller = desktopWindowController else { return }
        if settings.widgetEnabled {
            controller.showWindow(nil)
        } else {
            controller.window?.orderOut(nil)
        }
    }

    /// One collect-merge-write cycle, run off the main thread since it
    /// copies + reads knowledgeC.db (see Data/Store.swift). Falls back to
    /// whatever history is already on disk when the live read fails –
    /// e.g. no Full Disk Access – so a transient/permanent read failure
    /// doesn't blank out a widget that has real cached days to show.
    /// Only genuinely nothing-to-show (no access *and* no history yet)
    /// renders the Full-Disk-Access instructions.
    private func refresh(settings: Settings) {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cached = store.loadPrevious()
            do {
                let snapshot = try store.refresh(settings: settings)
                DispatchQueue.main.async {
                    self?.viewModel.state = .data(days: snapshot.days, tracked: true)
                }
            } catch {
                appLog("Store.refresh (initial) failed: \(error)")
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !cached.isEmpty {
                        self.viewModel.state = .data(days: cached, tracked: false)
                    } else if Self.isNoAccessError(error) {
                        self.viewModel.state = .noAccess
                    } else {
                        self.viewModel.state = .failed("\(error)")
                    }
                }
            }
        }
    }

    /// Mirrors aggregate.py's `except (PermissionError, FileNotFoundError,
    /// sqlite3.OperationalError)` → `no_access` classification. The FDA
    /// wall in practice bites at `Knowledge.copyAside` (copying the
    /// protected db aside), which surfaces as `.notFound` (TCC can make
    /// the file invisible to `fileExists`) or `.copyFailed`; opening the
    /// already-copied temp file never hits TCC, so a `.sqlite` error here
    /// means something else (corrupt db, bad query) and is a genuine
    /// failure, not a permissions problem.
    private static func isNoAccessError(_ error: Error) -> Bool {
        switch error {
        case Knowledge.KnowledgeError.notFound, Knowledge.KnowledgeError.copyFailed:
            return true
        default:
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app: closing the desktop window (there is no title bar
        // close button anyway, but be defensive) must not quit the app.
        false
    }
}

if CommandLine.arguments.contains("--self-test") {
    // Stage 2 test entry point. No XCTest available on this machine (CLT
    // only, no full Xcode – see SelfTest/SelfTestHarness.swift), so tests
    // live in the normal executable and run headless before any AppKit
    // setup happens.
    exit(SelfTest.runAll())
}

if CommandLine.arguments.contains("--check-fda") {
    // Stage 4 diagnostic: runs the exact same check the settings window's
    // access indicator uses (UI/SettingsWindow.swift's `FullDiskAccess`),
    // outside of AppKit/SwiftUI, so it can be confirmed from a shell
    // without needing to see the window render.
    switch FullDiskAccess.check() {
    case .granted: print("granted")
    case .denied: print("denied")
    }
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
