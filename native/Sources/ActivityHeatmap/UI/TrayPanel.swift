import AppKit
import SwiftUI

/// Screen 3 of the design handoff (`Ki App Settings.dc.html`, "3 · ТРЕЙ-МЕНЮ"):
/// a 264pt glass panel hanging off the menu bar icon, with the widget toggle
/// and its status on top, then Settings and Quit.
///
/// This replaces a plain `NSMenu`. An `NSMenu` cannot be styled at all – no
/// glass, no embedded switch, no two-line row – so the designed panel has to be
/// a real view. `NSPopover` hosts it because it already solves the parts that
/// are easy to get wrong by hand: dismissal on click-outside, staying on the
/// right screen, and the arrow pointing back at the status item.
///
/// Known deviation: the popover draws its own container, so its corner radius
/// and arrow are the system's rather than the mockup's radius 20 and drawn
/// tail. Everything inside the panel is the design's.
struct TrayPanelView: View {
    @ObservedObject var store: SettingsStore
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    private var s: L10n { L10n(store.settings.language) }
    private var glass: KiGlassStyle { KiGlassStyle(intense: store.settings.liquidGlass) }

    var body: some View {
        VStack(spacing: 4) {
            widgetRow
            Rectangle()
                .fill(SettingsTokens.ink07)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            TrayMenuRow(
                title: s.menuSettings,
                dot: SettingsTokens.accent,
                tint: SettingsTokens.ink85,
                highlight: SettingsTokens.accent.opacity(0.14),
                action: onOpenSettings
            )
            TrayMenuRow(
                title: s.menuQuit,
                dot: SettingsTokens.ink(0.3),
                tint: SettingsTokens.ink(0.6),
                highlight: SettingsTokens.ink06,
                action: onQuit
            )
        }
        .padding(10)
        .frame(width: 264)
        .environment(\.kiGlass, glass)
        .background(panelBackground)
    }

    /// Glass keeps the popover's own material and lays the veil over it.
    /// Regular has to paint its own opaque surface: `veil` is empty for that
    /// material, so without this the panel fell through to whatever the system
    /// popover draws — which is not the design's flat toolbar grey, and was the
    /// one surface still ignoring the material switch.
    @ViewBuilder
    private var panelBackground: some View {
        if glass.intense {
            LinearGradient(colors: glass.veil, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            glass.toolbarFill ?? glass.windowFill
        }
    }

    /// The widget switch, with the status line the mockup puts under it:
    /// mint "Отслеживание активно" when on, muted "Выключен" when off. This is
    /// the same `SettingsStore` the settings window writes, so the two can
    /// never disagree.
    private var widgetRow: some View {
        let on = store.settings.widgetEnabled
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.trayWidget)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTokens.ink90)
                Text(on ? s.trayTrackingActive : s.trayTrackingOff)
                    .font(.system(size: 11))
                    .foregroundStyle(on ? SettingsTokens.mint : SettingsTokens.ink45)
            }
            Spacer(minLength: 12)
            SettingsSwitch(
                isOn: Binding(
                    get: { store.settings.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }
                ),
                width: 40,
                height: 24
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(glass.groupFill)
        )
    }
}

/// One menu line: a 6pt square marker, a label, and a hover fill – the
/// mockup's "Настройки…" and "Выход" rows.
private struct TrayMenuRow: View {
    let title: String
    let dot: Color
    let tint: Color
    let highlight: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? highlight : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}
