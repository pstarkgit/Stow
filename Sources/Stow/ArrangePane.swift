import AppKit
import SwiftUI

/// Arrange: a live mirror of the real menu bar with Stow's marker drawn in it.
///
/// There is nothing to apply. The user holds Command and drags icons in the actual menu bar;
/// macOS honours the drag and remembers it. This pane shows which side of the boundary each
/// icon is on right now, ticks the stowed ones, and records the result as the user's decision
/// so later drift and new arrivals can be pointed out rather than acted on.
struct ArrangeContentView: View {
    let screen: NSScreen?

    @EnvironmentObject private var hider: HideController
    @EnvironmentObject private var store: Store

    @State private var owners: [BarItemOwners.Owner] = []
    @State private var showSystemItems = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                mirror
                statusRow
                noticeCards
                systemSummary
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The whole run is shown while this pane is open, so the user can see what they are
        // dragging. Refreshes read the bar; they never change it.
        .task(id: screen?.displayID) {
            if hider.presentation == .tidy { hider.reveal() }
            while !Task.isCancelled {
                _ = hider.refresh(config: store.config)
                owners = BarItemOwners.lastKnownClaims
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear {
            // Leaving Arrange is the decision. Record where everything sits, then hide again if
            // anything is left of the marker.
            store.recordObservedZones(hider.observedZones)
            if !hider.hiddenBundleIDs.isEmpty { hider.hide() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arrange")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)
            Text("Hold ⌘ and drag icons in your menu bar. Anything left of the Stow marker is stowed.")
                .font(.system(size: 11.5))
                .foregroundStyle(StowTheme.inkSoft)
            Text("The bar is fully shown while this window is open. Stow never moves an icon for you, so nothing can be refused or left half done.")
                .font(.system(size: 10.5))
                .foregroundStyle(StowTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The mirror

    private var mirror: some View {
        let entries = hider.liveEntries
        let hidden = entries.filter(\.isHidden)
        let visible = entries.filter { !$0.isHidden }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text("YOUR MENU BAR")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(StowTheme.inkSoft)
                    .kerning(1.2)
                Text("live · left to right")
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
                Spacer()
            }
            if entries.isEmpty {
                Text("Stow has not seen any third-party items on the bar yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(StowTheme.inkMuted)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hidden, id: \.bundleID) { entry in
                            MirrorTile(entry: entry, icon: icon(for: entry))
                        }
                        marker
                        ForEach(visible, id: \.bundleID) { entry in
                            MirrorTile(entry: entry, icon: icon(for: entry))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(StowTheme.hairline, lineWidth: 1))
    }

    private var marker: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(StowTheme.sweep(for: .tidy))
                .frame(width: 3, height: 34)
                .clipShape(Capsule())
            Text("STOW")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                .kerning(0.8)
        }
        .padding(.horizontal, 6)
        .help("Stow's marker. Icons left of it are stowed; icons right of it stay on the bar.")
    }

    private func icon(for entry: HideController.LiveEntry) -> NSImage? {
        NSRunningApplication(processIdentifier: entry.pid)?.icon
    }

    // MARK: - Status and actions

    private var statusRow: some View {
        let hidden = hider.hiddenBundleIDs.count
        let visible = hider.visibleBundleIDs.count
        return HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
            Text(hidden == 0
                 ? "Nothing is left of the marker yet. Drag an icon across it to stow it."
                 : "\(hidden) in Stow · \(visible) on the bar. Saved by macOS; nothing to apply.")
                .font(.system(size: 10.5))
                .foregroundStyle(StowTheme.inkSoft)
            Spacer(minLength: 8)
            if hidden > 0 {
                Button(hider.presentation == .tidy ? "Show All" : "Hide Now") {
                    hider.toggle()
                }
                .buttonStyle(.bordered)
                .help("Hide or show the stowed run. This only changes the width of Stow's boundary.")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private var noticeCards: some View {
        ForEach(hider.notices) { notice in
            NoticeCard(notice: notice,
                       name: Self.displayName(forBundleID: notice.bundleID),
                       icon: Self.icon(forBundleID: notice.bundleID),
                       keep: {
                           store.setZone(notice.kind == .slippedIntoStow ? .tucked : .pinned,
                                         forBundleID: notice.bundleID)
                           hider.dismissNotice(notice.bundleID)
                       },
                       later: { hider.dismissNotice(notice.bundleID) })
        }
    }

    /// Apple's own items, collapsed to one line. Stow cannot address them individually and
    /// they are laid out by the system, so they are not part of this decision at all.
    private var systemSummary: some View {
        let system = owners
            .filter { VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID) }
            .sorted { $0.axLeftEdge > $1.axLeftEdge }

        return Group {
            if !system.isEmpty {
                DisclosureGroup(isExpanded: $showSystemItems) {
                    Text(system.map(\.name).joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(StowTheme.inkMuted)
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(StowTheme.inkMuted)
                        Text("System items stay visible")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(StowTheme.inkSoft)
                        Text("\(system.count)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                }
                .tint(StowTheme.inkMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Aurora.inset, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StowTheme.hairline))
            }
        }
    }

    static func displayName(forBundleID bundleID: String) -> String {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first {
            return running.icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - one tile

private struct MirrorTile: View {
    let entry: HideController.LiveEntry
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 12))
                        .foregroundStyle(StowTheme.inkMuted)
                        .frame(width: 20, height: 20)
                }
                if entry.isHidden {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                        .background(Circle().fill(StowTheme.canvas))
                        .offset(x: 5, y: -5)
                }
            }
            Text(entry.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(StowTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Aurora.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(entry.isHidden
                        ? (StowTheme.stops(for: .tidy).first ?? StowTheme.blue).opacity(0.45)
                        : StowTheme.hairline,
                        lineWidth: 1))
        .help(entry.isHidden ? "\(entry.name) is in Stow" : "\(entry.name) stays on the bar")
    }
}

// MARK: - one notice

private struct NoticeCard: View {
    let notice: HideController.LayoutNotice
    let name: String
    let icon: NSImage?
    let keep: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed").frame(width: 24, height: 24)
                    .foregroundStyle(StowTheme.inkMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StowTheme.ink)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Later", action: later).buttonStyle(.bordered)
            Button(keepTitle, action: keep).buttonStyle(.borderedProminent)
        }
        .padding(11)
        .background(StowTheme.orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(StowTheme.orange.opacity(0.35), lineWidth: 1))
    }

    private var headline: String {
        switch notice.kind {
        case .backOnBar: return "\(name) is back on the visible side"
        case .slippedIntoStow: return "\(name) ended up in Stow"
        case .newApp: return "\(name) appeared on your bar"
        }
    }

    private var detail: String {
        switch notice.kind {
        case .backOnBar:
            return "Hold ⌘ and drag it left of the Stow marker to stow it again, or keep it where it is."
        case .slippedIntoStow:
            return "Hold ⌘ and drag it right of the Stow marker to bring it back, or keep it stowed."
        case .newApp:
            return "It stays visible until you decide. To stow it, hold ⌘ and drag it left of the marker."
        }
    }

    private var keepTitle: String {
        notice.kind == .slippedIntoStow ? "Keep in Stow" : "Keep on Bar"
    }
}
