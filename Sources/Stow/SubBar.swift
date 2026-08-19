import AppKit
import SwiftUI

/// One app the panel offers, with everything needed to draw and press it.
///
/// Separate from `StatusPanel.VisibleRow` because the panel's job changed. It used to list
/// what was ON the bar, which is the one set the user can already reach by clicking the icons
/// themselves. What they cannot reach is what Stow has hidden, so that is what the panel
/// shows now.
///
/// Keyed by bundle, and carrying its own pid, because a hidden item is not in a bar scan at
/// all: `BarItemOwners.claims()` filters to `x > 0` and a pushed item reports a large negative
/// position, so it vanishes from the walk entirely. The pid is resolved from the bundle
/// instead.
struct HiddenApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let zone: Zone
    let pid: pid_t

    var id: String { bundleID }

    static func == (lhs: HiddenApp, rhs: HiddenApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.zone == rhs.zone && lhs.pid == rhs.pid
    }
}

/// The sub-bar: the apps Stow is hiding, as icons you can click.
///
/// This is design §8's "the sub-bar owns the everyday interaction", and it only works because
/// of one measured fact: an item pushed off the bar can still be OPENED. Verified on a real
/// hidden app, Vendor Agent sitting at x-3036, pressed through the accessibility API: its menu opened,
/// windows at pop-up-menu level going 3 to 4. So a tucked app is reachable without revealing
/// anything, which is what makes hiding it worth doing.
///
/// Icons are 26pt, deliberately larger than the 20pt first tried. At 20pt in a 34pt tile they
/// read as small even beside the menu bar's own ~22pt glyphs, and this is the surface where
/// recognising the icon IS the interaction.
struct SubBar: View {
    let apps: [HiddenApp]
    let state: BarState
    /// Opens one app's menu, without changing what is hidden.
    let onOpen: (HiddenApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionKicker(title: "HIDDEN", state: state, badge: apps.count)

            if apps.isEmpty {
                Text("nothing is hidden. Set an app to Tucked in Arrange.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowRow(spacing: 7) {
                    ForEach(apps) { app in
                        SubBarIcon(app: app) { onOpen(app) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

}

/// One hidden app as a pressable icon.
private struct SubBarIcon: View {
    let app: HiddenApp
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? StowTheme.cardHover : Aurora.raised)
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 16))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                }
                .frame(width: 42, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hovering ? StowTheme.hairline : .clear, lineWidth: 1))

                // A short name under each icon, unlike the on-bar tiles which had none.
                // Here it earns its space: a hidden app is one the user cannot see in the bar,
                // so the icon alone has no context to be recognised against.
                Text(app.name)
                    .font(.system(size: 9))
                    .foregroundStyle(hovering ? StowTheme.ink : StowTheme.inkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: 52)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(app.name) without un-hiding it")
        .accessibilityLabel(app.name)
        .accessibilityHint("Opens this app's menu without un-hiding it")
    }
}
