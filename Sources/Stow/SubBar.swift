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

/// A second menu bar for the apps Stow is hiding.
///
/// This is design §8's "the sub-bar owns the everyday interaction", and it only works because
/// of one measured fact: an item pushed off the bar can still be OPENED. Verified on a real
/// hidden app, Vendor Agent sitting at x-3036, pressed through the accessibility API: its menu opened,
/// windows at pop-up-menu level going 3 to 4. So a tucked app is reachable without revealing
/// anything, which is what makes hiding it worth doing.
///
/// Apps stay in one horizontal run, matching the surface they came from. Ten fit at the panel's
/// normal width; larger sets scroll instead of wrapping into a grid. Hover reveals the app name
/// in the section header without making every icon carry a permanent caption.
struct SubBar: View {
    enum ShelfLayout: Equatable {
        case inline
        case scrolling
    }

    /// Chooses the first layout that actually fits rather than keeping a second hardcoded app
    /// limit beside the panel width. The arithmetic mirrors the rendered shelf: 12pt outer
    /// padding per side, a 72pt action, 1pt divider, 5pt inner padding per side, 34pt icons,
    /// and 3pt gaps. At the 500pt panel width ten apps fit and the eleventh scrolls.
    nonisolated static func shelfLayout(appCount: Int, panelWidth: CGFloat) -> ShelfLayout {
        let available = panelWidth - 24 - 72 - 1
        let icons = CGFloat(max(0, appCount)) * 34
        let gaps = CGFloat(max(0, appCount - 1)) * 3
        let required = 10 + icons + gaps
        return required <= available ? .inline : .scrolling
    }

    let apps: [HiddenApp]
    let state: BarState
    let revealPresentation: RevealPresentation?
    let actionTitle: String
    let actionSymbol: String
    /// Opens one app's menu, without changing what is hidden.
    let onOpen: (HiddenApp) -> Void
    let onToggle: () -> Void

    @State private var hoveredAppName: String?
    @State private var hoveringAction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("In Stow")
                    .font(.subheadline)
                    .foregroundStyle(StowTheme.ink)
                Spacer()
                Text(hoveredAppName ?? appCountLabel)
                    .font(.caption)
                    .foregroundStyle(StowTheme.inkSoft)
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                if Self.shelfLayout(appCount: apps.count,
                                    panelWidth: StatusPanel.panelWidth) == .inline {
                    HStack(spacing: 3) {
                        if apps.isEmpty {
                            Text("No hidden apps")
                                .font(.caption)
                                .foregroundStyle(StowTheme.inkMuted)
                                .padding(.leading, 4)
                        } else {
                            ForEach(apps) { app in
                                appButton(app)
                            }
                        }
                    }
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44,
                           alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(apps) { app in
                                appButton(app)
                            }
                        }
                        .padding(.horizontal, 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                }

                Rectangle()
                    .fill(StowTheme.hairline)
                    .frame(width: 1, height: 30)

                Button(action: onToggle) {
                    VStack(spacing: 2) {
                        Image(systemName: actionSymbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(actionTitle)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(hoveringAction ? StowTheme.ink : StowTheme.inkSoft)
                    .frame(width: 72, height: 44)
                    .background(hoveringAction ? StowTheme.cardHover : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringAction = $0 }
            }
            .background(Aurora.raised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(StowTheme.sweep(for: state), lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private var appCountLabel: String {
        apps.count == 1 ? "1 app" : "\(apps.count) apps"
    }

    @ViewBuilder
    private func appButton(_ app: HiddenApp) -> some View {
        SubBarIcon(app: app,
                   presentation: revealPresentation,
                   onHover: { hovering in
                       if hovering {
                           hoveredAppName = app.name
                       } else if hoveredAppName == app.name {
                           hoveredAppName = nil
                       }
                   },
                   onOpen: { onOpen(app) })
    }
}

/// One hidden app as a pressable icon.
private struct SubBarIcon: View {
    let app: HiddenApp
    let presentation: RevealPresentation?
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 15))
                        .foregroundStyle(StowTheme.inkMuted)
                }
                if let presentation, presentation.matches(app.bundleID) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        Circle()
                            .stroke(StowTheme.hairline, lineWidth: 2)
                            .overlay {
                                Circle()
                                    .trim(from: 0, to: presentation.progress(at: context.date))
                                    .stroke(StowTheme.sweep(for: .tidy),
                                            style: StrokeStyle(lineWidth: 2,
                                                               lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: 34, height: 38)
            .background(hovering ? StowTheme.cardHover : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            onHover($0)
        }
        .help("Open \(app.name) without un-hiding it")
        .accessibilityLabel(app.name)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        guard let presentation, presentation.matches(app.bundleID) else {
            return "Temporarily shows this app on the menu bar and opens its menu"
        }
        return "Returns to Stow in \(presentation.secondsRemaining(at: Date())) seconds"
    }
}
