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
    /// Apps the user has explicitly picked for the next real Command-drag. This is deliberately
    /// separate from `liveEntries`: choosing an app must not pretend it has already moved.
    @State private var plannedStowBundleIDs: Set<String> = []
    @State private var isArrangingSelectedApps = false
    @State private var showArrangeConfirmation = false
    @State private var arrangementResult: String?
    @State private var arrangementFailures: [String] = []
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
        // dragging. Take one snapshot, then leave the mirror alone while they interact. A timer
        // here made the SwiftUI tiles reorder every second, stealing the user's place mid-drag.
        .task(id: screen?.displayID) {
            if hider.presentation == .tidy { hider.reveal() }
            refreshBar()
        }
        .onDisappear {
            // Leaving Arrange is the decision. Record where everything sits, then hide again if
            // anything is left of the marker.
            store.recordObservedZones(hider.observedZones)
            if !hider.hiddenBundleIDs.isEmpty { hider.hide() }
        }
        .alert("Stow selected apps?", isPresented: $showArrangeConfirmation) {
            Button("Stow \(plannedVisibleEntries.count) Selected", role: .destructive) {
                startSelectedArrangement()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stow will temporarily hide and move your pointer while it performs the same ⌘-drags you would. It verifies every app afterward. If one fails, Stow shows everything rather than hiding a partial bar.")
        }
    }

    private func startSelectedArrangement() {
        guard !plannedVisibleEntries.isEmpty, !isArrangingSelectedApps else { return }
        isArrangingSelectedApps = true
        arrangementResult = nil
        arrangementFailures = []

        // Give SwiftUI one turn to paint the in-progress state before the bounded main-actor
        // arrangement uses the run loop to wait for macOS's menu bar.
        Task { @MainActor in
            await Task.yield()
            performSelectedArrangement()
        }
    }

    private func performSelectedArrangement() {
        let plan = plannedVisibleEntries
        defer { isArrangingSelectedApps = false }
        guard !plan.isEmpty else { return }

        // The action is scoped to exactly the apps the user picked. Preserve the observed side of
        // every other live item so the arranger treats it as already correct and never moves it.
        var target = store.config
        for entry in hider.liveEntries {
            target.setZone(entry.isHidden ? .tucked : .pinned, forBundleID: entry.bundleID)
        }
        for entry in plan {
            target.setZone(.tucked, forBundleID: entry.bundleID)
        }

        // The boundary must be rested while these items cross it. This does not move any app.
        hider.showEverything()
        let outcome = BarArranger.arrange(config: target, seamWindow: hider.tuckedSeamWindow)
        BarArranger.log(outcome, context: "selected-stow requested=\(plan.map(\.bundleID).joined(separator: ","))")

        if outcome.isClean {
            _ = hider.refresh(config: target)
            store.recordObservedZones(hider.observedZones)
            plannedStowBundleIDs.subtract(hider.hiddenBundleIDs)
            hider.hide()
            arrangementResult = outcome.moved.isEmpty
                ? "Those apps were already on Stow's side. The bar is now hidden."
                : "Stowed \(outcome.moved.count) app\(outcome.moved.count == 1 ? "" : "s")."
        } else {
            // Fail open. macOS may have accepted some of the requested drags, but the entire bar
            // remains visible so the user can see and correct every real position.
            hider.showEverything()
            _ = hider.refresh(config: store.config)
            arrangementFailures = outcome.failed.map {
                "\(Self.displayName(forBundleID: $0.bundleID ?? "Stow")): \($0.reason)"
            }
            arrangementResult = "Stow showed everything because the selected arrangement was incomplete."
        }
    }

    private func refreshBar() {
        _ = hider.refresh(config: store.config)
        owners = BarItemOwners.lastKnownClaims
        // A checked-off plan becomes history only after the real bar confirms it crossed the
        // marker. Until then the selected app remains in the user's short placement list.
        plannedStowBundleIDs.subtract(hider.hiddenBundleIDs)
    }

    private func toggleStowPlan(for entry: HideController.LiveEntry) {
        guard !entry.isHidden else { return }
        if !plannedStowBundleIDs.insert(entry.bundleID).inserted {
            plannedStowBundleIDs.remove(entry.bundleID)
        }
    }

    private var plannedVisibleEntries: [HideController.LiveEntry] {
        hider.liveEntries.filter {
            !$0.isHidden && plannedStowBundleIDs.contains($0.bundleID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arrange")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)
            Text("Pick the apps you want in Stow, then choose Stow Selected. That confirmed action performs the same ⌘-drags you would.")
                .font(.system(size: 11.5))
                .foregroundStyle(StowTheme.inkSoft)
            Text("1 Pick here  ·  2 Stow Selected  ·  3 Stow verifies and hides. Stow will briefly control the pointer only in step 2.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
            Text("The bar is fully shown while this window is open. Stow moves icons only after you choose Stow Selected and confirm; profiles, refresh, and ordinary hide/show never move them.")
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
                Text("snapshot · left to right")
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
                VStack(spacing: 12) {
                    zoneRow(title: "ON BAR",
                            detail: "right of Stow's marker · click an app to add it to Stow",
                            entries: visible,
                            selectable: true)
                    zoneRow(title: "IN STOW",
                            detail: "left of Stow's marker",
                            entries: hidden,
                            selectable: false)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(StowTheme.hairline, lineWidth: 1))
    }

    private func zoneRow(title: String,
                         detail: String,
                         entries: [HideController.LiveEntry],
                         selectable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: selectable ? "menubar.rectangle" : "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selectable ? StowTheme.inkSoft : (StowTheme.stops(for: .tidy).first ?? StowTheme.blue))
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StowTheme.inkSoft)
                    .kerning(1)
                Text("\(entries.count) · \(detail)")
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
            }
            if entries.isEmpty {
                Text(selectable ? "Nothing on the bar is available to add." : "Nothing is currently stowed.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkMuted)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(entries, id: \.bundleID) { entry in
                        if selectable {
                            Button {
                                toggleStowPlan(for: entry)
                            } label: {
                                MirrorTile(entry: entry,
                                           icon: icon(for: entry),
                                           isPlannedForStow: plannedStowBundleIDs.contains(entry.bundleID))
                            }
                            .buttonStyle(.plain)
                            .help(plannedStowBundleIDs.contains(entry.bundleID)
                                  ? "Remove \(entry.name) from the Stow setup list"
                                  : "Add \(entry.name) to the Stow setup list")
                        } else {
                            MirrorTile(entry: entry, icon: icon(for: entry), isPlannedForStow: false)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectable ? Aurora.inset : (StowTheme.stops(for: .tidy).first ?? StowTheme.blue).opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(StowTheme.hairline, lineWidth: 1))
    }

    private func icon(for entry: HideController.LiveEntry) -> NSImage? {
        NSRunningApplication(processIdentifier: entry.pid)?.icon
    }

    // MARK: - Status and actions

    private var statusRow: some View {
        let hidden = hider.hiddenBundleIDs.count
        let visible = hider.visibleBundleIDs.count
        let plan = plannedVisibleEntries

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: plan.isEmpty ? "hand.point.up.left.fill" : "list.bullet.circle.fill")
                    .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                Text(plan.isEmpty
                     ? "Step 1: click any app on the visible side to add it to your Stow list."
                     : "Step 2: \(plan.count) app\(plan.count == 1 ? "" : "s") ready to stow.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(StowTheme.inkSoft)
                Spacer(minLength: 8)
                if !plan.isEmpty {
                    Button(isArrangingSelectedApps
                           ? "Stowing…"
                           : "Stow \(plan.count) Selected") {
                        showArrangeConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isArrangingSelectedApps)
                    .help("Move only the selected apps across Stow's marker after a confirmation.")
                }
                Button("Refresh Bar", action: refreshBar)
                    .buttonStyle(.bordered)
                    .help("Read the current menu bar after you finish a drag. The mirror stays still until you choose this.")
                if hidden > 0 {
                    Button(hider.presentation == .tidy ? "Show All" : "Hide Now") {
                        hider.toggle()
                    }
                    .buttonStyle(.bordered)
                    .help("Hide or show the stowed run. This only changes the width of Stow's boundary.")
                }
            }

            if !plan.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "command")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(StowTheme.orange)
                    Text("Ready: \(plan.map(\.name).joined(separator: ", ")). Choose Stow \(plan.count) Selected, then confirm. Stow will verify every move and hide only if all selected apps land.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(StowTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Clear", role: .cancel) { plannedStowBundleIDs.removeAll() }
                        .buttonStyle(.borderless)
                }
                .padding(.leading, 22)
            } else if hidden > 0 {
                Text("\(hidden) in Stow · \(visible) on the bar. Green checks mean the icon is already physically left of the marker.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkMuted)
                    .padding(.leading, 22)
            }
            if let arrangementResult {
                VStack(alignment: .leading, spacing: 4) {
                    Label(arrangementResult,
                          systemImage: arrangementFailures.isEmpty
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(arrangementFailures.isEmpty
                                         ? (StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                                         : StowTheme.orange)
                    ForEach(arrangementFailures, id: \.self) { failure in
                        Text(failure)
                            .font(.system(size: 10))
                            .foregroundStyle(StowTheme.inkSoft)
                    }
                }
                .padding(.leading, 22)
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
    let isPlannedForStow: Bool

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
                } else if isPlannedForStow {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(StowTheme.orange)
                        .background(Circle().fill(StowTheme.canvas))
                        .offset(x: 5, y: -5)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(StowTheme.ink)
                    .lineLimit(1)
                Text(entry.isHidden ? "IN STOW" : isPlannedForStow ? "TO STOW" : "ON BAR")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(entry.isHidden
                                     ? (StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                                     : isPlannedForStow ? StowTheme.orange : StowTheme.inkMuted)
                    .kerning(0.4)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Aurora.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(entry.isHidden
                        ? (StowTheme.stops(for: .tidy).first ?? StowTheme.blue).opacity(0.45)
                        : isPlannedForStow ? StowTheme.orange.opacity(0.7) : StowTheme.hairline,
                        lineWidth: isPlannedForStow ? 1.5 : 1))
        .help(entry.isHidden
              ? "\(entry.name) is already in Stow"
              : isPlannedForStow ? "\(entry.name) is on your Stow setup list" : "Click to add \(entry.name) to your Stow setup list")
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
