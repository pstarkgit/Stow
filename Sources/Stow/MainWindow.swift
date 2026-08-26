import SwiftUI
import AppKit
import CoreGraphics
import ServiceManagement

/// The one big window: a sidebar of destinations, same shape AuthBar and Murmur
/// already proved.
///
/// AuthBar collapsed its separate Settings and Doctor windows into one
/// `MainWindow` with a `Destination` enum, keeping the window id `"settings"` so
/// every existing `openWindow(id:)` call site survived. This is that same shape
/// for Stow: one window, six destinations grouped by what they are FOR (arranging
/// the bar, checking its health, or configuring the app) rather than one window
/// per concern.
///
/// Arrange and Profiles are live product surfaces backed by the same persisted store and
/// transactional arranger. Rules remains an explicit preview until its context evaluator ships.
struct MainWindow: View {
    /// Which destination to show. A `Binding` rather than local `@State`, matching
    /// AuthBar's `MainWindow` exactly: it lets a future caller (the sub-bar's gear,
    /// once it exists) land the window on a specific destination rather than
    /// whatever it last showed. `App.swift` owns the `@State` this binds to and
    /// hosts the `Window(id: MainWindow.windowID)` scene; wiring that scene is
    /// this stage's counterpart's job, not this file's.
    @Binding var destination: Destination

    /// Owned here, not by `BarDoctorView`, so the sidebar's Doctor badge reflects
    /// live findings before that destination is ever opened. Both this window and
    /// the Doctor pane observe the SAME instance; only this window's `.task`
    /// drives it, so navigating to Doctor never triggers a second, redundant run.
    @StateObject private var doctor = BarDoctor()
    @State private var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @ObservedObject private var target = WindowTarget.shared
    @EnvironmentObject private var hider: HideController

    /// The screen the header's display picker currently has selected. Falls back
    /// through `NSScreen.main` and the first available screen so a display that
    /// was unplugged since the picker last ran never leaves this `nil` when a
    /// perfectly good screen is still attached.
    private var selectedScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == selectedDisplayID }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StowTheme.hairline)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(StowTheme.hairline)
                detail
            }
        }
        .frame(minWidth: 780, idealWidth: 880, maxWidth: .infinity,
               minHeight: 500, idealHeight: 600, maxHeight: .infinity)
        .background(StowTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
        // Adopt a PENDING request only, same rationale AuthBar's MainWindow
        // documents: assigning unconditionally on appear would mean the window
        // always opened wherever WindowTarget last pointed, including its
        // default, so a future gear icon could never land on a specific
        // destination. The request is consumed once and cleared.
        .onAppear { consumeRequest() }
        .onChange(of: target.pending) { _, _ in consumeRequest() }
        // Runs on first appearance (the initial id) and again whenever the
        // display picker changes, since the point-math and coverage checks are
        // both per-display. This is the ONLY place `doctor.run` is called from;
        // `BarDoctorView` only reads the shared instance and offers a manual
        // re-run button, so switching to Doctor never double-runs the checks.
        .task(id: selectedDisplayID) {
            await doctor.run(screen: selectedScreen,
                             spacerWidth: hider.measuredSeamWidth(),
                             seamWindows: hider.seamWindowNumbers())
        }
    }

    /// Where the next `openWindow(id: MainWindow.windowID)` should land.
    ///
    /// Ported from AuthBar's `WindowTarget` verbatim: the panel (or, later, the
    /// sub-bar) lives in a different scene than this window, so a plain `@State`
    /// cannot carry intent between them. `nil` means no pending request, and the
    /// window keeps whatever it is already showing.
    @MainActor
    final class WindowTarget: ObservableObject {
        static let shared = WindowTarget()
        @Published var pending: Destination?
        private init() {}

        func request(_ dest: Destination) { pending = dest }
    }

    /// The window id every `openWindow(id:)` call site targets. A stored constant
    /// rather than a literal repeated at each call site, so the id can only drift
    /// from `"settings"` in one place.
    static let windowID = "settings"

    private func consumeRequest() {
        guard let requested = target.pending else { return }
        destination = requested
        target.pending = nil
    }

    // MARK: - Header

    /// Full-width title row: the mark, the name, and the display picker. Design
    /// section 10 draws this ABOVE the sidebar-plus-detail split, not inside the
    /// sidebar the way AuthBar's brand block sits, because a display choice
    /// governs every destination below it, not just one.
    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: StowGlyph.image(for: .tidy))
                .frame(width: 18, height: 18)
            Text("Stow")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(StowTheme.ink)
            Text(StowVersion.display)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(StowTheme.inkMuted)
            Spacer(minLength: 12)
            if NSScreen.screens.count > 1 {
                AuroraMenu(options: displayOptions, selection: $selectedDisplayID)
            } else {
                healthChip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var displayOptions: [(value: CGDirectDisplayID, label: String, shortcut: String?)] {
        NSScreen.screens.map { ($0.displayID, $0.localizedName, nil) }
    }

    private var healthChip: some View {
        let summary = doctor.summary
        let healthy = summary.issueCount == 0
        return HStack(spacing: 6) {
            Circle()
                .fill(healthy ? (StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                              : StowTheme.orange)
                .frame(width: 6, height: 6)
                .shadow(color: healthy ? StowTheme.edgeGlow(for: .tidy) : .clear, radius: 3)
            Text(healthy ? "Healthy" : "\(summary.issueCount) to review")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(healthy ? StowTheme.inkSoft : StowTheme.orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Aurora.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(StowTheme.hairline))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("ORGANIZE", Destination.layout)
            group("HEALTH", Destination.health)
            group("STOW", Destination.app)
            Spacer(minLength: 12)
            utilities
        }
        .frame(width: 174)
        .background(
            ZStack(alignment: .top) {
                Color(red: 0.043, green: 0.051, blue: 0.067)
                GeometryReader { geo in
                    RadialGradient(
                        colors: [(StowTheme.stops(for: .tidy).first ?? .green).opacity(0.11), .clear],
                        center: .init(x: 0.4, y: 0),
                        startRadius: 0, endRadius: geo.size.width * 1.1)
                    .frame(height: 120)
                }
                .allowsHitTesting(false)
            }
        )
    }

    private func group(_ title: String, _ items: [Destination]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(1.7)
                .foregroundStyle(StowTheme.inkMuted)
                .padding(.horizontal, 15)
                .padding(.top, 13)
                .padding(.bottom, 6)
            VStack(spacing: 1) {
                ForEach(items) { row($0) }
            }
            .padding(.horizontal, 8)
        }
    }

    private func row(_ dest: Destination) -> some View {
        let selected = dest == destination
        return Button {
            destination = dest
        } label: {
            HStack(spacing: 9) {
                Image(systemName: dest.symbol)
                    .font(.system(size: 12))
                    .frame(width: 15, height: 15)
                    .foregroundStyle(selected
                                     ? AnyShapeStyle(StowTheme.diagonal(for: .tidy))
                                     : AnyShapeStyle(StowTheme.inkSoft))
                Text(dest.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? StowTheme.ink : StowTheme.inkSoft)
                Spacer(minLength: 4)
                if let badge = badge(for: dest) {
                    Text("\(badge.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(badge.urgent
                                         ? StowTheme.orange
                                         : StowTheme.inkSoft)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badge.urgent
                                    ? StowTheme.orange.opacity(0.18)
                                    : Color.white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selected
                        ? AnyShapeStyle(LinearGradient(
                            colors: [(StowTheme.stops(for: .tidy).first ?? .green).opacity(0.17),
                                     (StowTheme.stops(for: .tidy).last ?? .blue).opacity(0.10)],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StowTheme.sweep(for: .tidy))
                        .frame(width: 2.5)
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Nav badges: a count worth knowing before the pane is opened.
    ///
    /// Profiles' count is structural (there are exactly four named profiles, full
    /// stop). Doctor's is measured from `doctor.warnCount`, live, rather than the
    /// static illustrative "2" the design mock shows, matching the project's own
    /// "measured, never counted" rule from `BarBudget`'s header comment. It is
    /// shown only when there is something to flag; a badge reading "0" would be
    /// noise a warning badge exists specifically to avoid.
    private func badge(for dest: Destination) -> (count: Int, urgent: Bool)? {
        switch dest {
        case .doctor:
            let summary = doctor.summary
            return summary.issueCount > 0 ? (summary.issueCount, summary.hasWarning) : nil
        default:
            return nil
        }
    }

    private var utilities: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await doctor.run(screen: selectedScreen,
                                     spacerWidth: hider.measuredSeamWidth(),
                                     seamWindows: hider.seamWindowNumbers())
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StowTheme.blue)
            }
            .buttonStyle(.plain)
            .help("Re-run the Doctor's checks")
            .accessibilityLabel("Re-run the Doctor's checks")
            Spacer(minLength: 0)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StowTheme.rose)
            }
            .buttonStyle(.plain)
            .help("Quit Stow")
            .accessibilityLabel("Quit Stow")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(StowTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let w = geo.size.width
                let stops = StowTheme.stops(for: .tidy)
                ZStack(alignment: .top) {
                    RadialGradient(colors: [stops.first?.opacity(0.12) ?? .clear, .clear],
                                   center: .init(x: 0.28, y: 0),
                                   startRadius: 0, endRadius: w * 0.68)
                    RadialGradient(colors: [(stops.last ?? .clear).opacity(0.10), .clear],
                                   center: .init(x: 0.74, y: 0),
                                   startRadius: 0, endRadius: w * 0.68)
                }
                .frame(height: 120)
            }
            .allowsHitTesting(false)

            content(for: destination)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func content(for dest: Destination) -> some View {
        switch dest {
        case .arrange:
            ArrangeContentView(screen: selectedScreen)
        case .profiles:
            ProfilesContentView()
        case .rules:
            RulesContentView()
        case .doctor:
            // `chromeless: true` because this window already supplies the frame,
            // the canvas and the ambient glow above; drawing a second copy of all
            // three inside the Doctor pane would double the glow, same rationale
            // AuthBar's `AuthDoctorView.chromeless` documents.
            BarDoctorView(chromeless: true, doctor: doctor, screen: selectedScreen)
        case .whatsNew:
            // `WhatsNewPane` is authored by a concurrently-running stage of this
            // same build (design section 12 / PLAN 0 stage 0.2) reading
            // `CHANGELOG.md` from inside the bundle. Referenced by its bare type
            // name, exactly as AuthBar's own `MainWindow` references its
            // `WhatsNewPane`, so this file carries no protocol indirection the
            // design did not ask for. If that type is not yet present when this
            // module builds, reconciling the two stages is the dispatcher's job,
            // not a reason to stub this destination.
            WhatsNewPane()
        case .settings:
            SettingsContentView()
        }
    }
}

// MARK: - Destinations

extension MainWindow {
    /// Where the sidebar can take you, grouped the way design section 10 groups
    /// them: LAYOUT ("shape the bar"), HEALTH ("is it working"), APP ("how should
    /// it behave"). `String` raw values, `CaseIterable`, and no explicit
    /// `Equatable`/`Hashable` conformance, matching `RevealPath` and `Zone` in
    /// `Models.swift`: a raw-value enum with no associated values gets both
    /// synthesized for free, and `row(_:)`'s `==` and this window's
    /// `.task(id:)`-adjacent `.onChange` both rely on that.
    enum Destination: String, Identifiable, CaseIterable {
        case arrange, profiles, rules, doctor, whatsNew, settings

        var id: String { rawValue }

        static let layout: [Destination] = [.arrange, .profiles, .rules]
        static let health: [Destination] = [.doctor]
        static let app: [Destination] = [.whatsNew, .settings]

        var title: String {
            switch self {
            case .arrange:  return "Arrange"
            case .profiles: return "Profiles"
            case .rules:    return "Rules"
            case .doctor:   return "Doctor"
            case .whatsNew: return "What's New"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .arrange:  return "rectangle.3.group"
            case .profiles: return "square.stack.3d.up"
            case .rules:    return "arrow.triangle.2.circlepath"
            case .doctor:   return "stethoscope"
            case .whatsNew: return "sparkles"
            case .settings: return "gearshape"
            }
        }
    }
}

// MARK: - Arrange

/// The measured menu bar split into the two zones Stow actually supports.
///
/// The two zones themselves, On Bar and In Stow, are
/// persisted policy in `Store.swift`. The pane also shows which items the window server
/// currently reports on the bar versus pushed off it, with the same measured
/// arithmetic `BarBudget` already computes for `canReveal`.
private struct ArrangeContentView: View {
    let screen: NSScreen?

    @EnvironmentObject private var hider: HideController
    @EnvironmentObject private var store: Store

    @State private var scan: BarScanner.ScanResult?
    @State private var budget: BarBudget?
    /// Every claim from `BarItemOwners.claims()`, held in state so every row in
    /// this pane resolves against ONE walk of every running application's
    /// `AXExtrasMenuBar` rather than re-walking it per row.
    @State private var owners: [BarItemOwners.Owner] = []
    /// True while apps are moving, so the pane can show progress.
    @State private var movingCut = false
    /// The pending coalesced apply, so a burst of drags cancels its predecessor rather than
    /// queueing another full seam move behind it. See `apply(outcome:)`.
    @State private var applyTask: Task<Void, Never>?
    /// Stow's seam window number, so it is excluded from occupancy arithmetic.
    @State private var seamWindows: Set<CGWindowID> = []
    @State private var showSystemItems = false


    var body: some View {
        // Scrollable, because it is not: on a 16 item bar the list ran past the
        // bottom of the window with no way to reach the rest of it, and the header
        // and footer went with it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if scan == nil {
                    ProgressView().controlSize(.small).tint(StowTheme.blue)
                } else {
                    decisionList
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: screen?.displayID) { await rescan() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arrange")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)
            Text("Choose what stays visible and what waits in Stow.")
                .font(.system(size: 11.5))
                .foregroundStyle(StowTheme.inkSoft)
            Text("Drag an app across the boundary. Changes save automatically.")
                .font(.system(size: 10.5))
                .foregroundStyle(StowTheme.inkMuted)
        }
    }

    /// States the actual mechanism, because the previous banner described a
    /// limitation that no longer exists and promised a feature that cannot exist.
    ///
    /// It said dragging a tile between zones was "not wired yet", implying zones were
    /// coming. They are not reachable this way: no API moves another app's status
    /// item, and a synthesised Command-drag was measured leaving an item exactly where
    /// it started. What Stow genuinely controls is where its own seam sits, and the
    /// seam is the cut: everything to its left leaves the bar. So the honest control
    /// is choosing the cut, which is what this pane now offers.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag apps between On Bar and In Stow.")
                .font(.system(size: 11.5))
                .foregroundStyle(StowTheme.ink)
            Text("Stow moves only the apps you choose, verifies the result, and restores"
                 + " the previous layout if macOS refuses any part of the change.")
                .font(.system(size: 11))
                .foregroundStyle(StowTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(StowTheme.hairline, lineWidth: 1))
    }

    /// The bar as a list of CHOICES: checked means the app is on the bar.
    ///
    /// Two things about this shape are deliberate and were both wrong in an earlier
    /// build.
    ///
    /// It reads checked = SHOWN, not checked = hide. A checkbox beside an app name reads
    /// as "this app is on my menu bar", so the inverted sense made the list state the
    /// opposite of what it displayed.
    ///
    /// And it lists apps that are currently HIDDEN, not just what is on the bar right
    /// now. Listing only on-bar items meant an app vanished from the list the moment it
    /// was hidden, leaving no box to re-check and no way back. Their positions come from
    /// `BarHomes`, because a pushed item's live position is far off-screen and says
    /// nothing about where it belongs.
    private var decisionList: some View {
        let candidates = candidateApps()

        return VStack(alignment: .leading, spacing: 10) {
            if candidates.isEmpty {
                emptyNote("Stow has not seen any third-party items on the bar yet")
            } else {
                ZoneBoard(
                    tiles: candidates.map { candidate in
                        ZoneBoard.Tile(
                            bundleID: candidate.plan.bundleID,
                            name: candidate.name,
                            icon: candidate.icon,
                            isOnBarNow: candidate.isOnBarNow)
                    },
                    zoneOf: { store.config.zone(forBundleID: $0) },
                    onMove: { bundle, zone in
                        store.setZone(zone, forBundleID: bundle)
                        // The zone is saved and drawn NOW; the seam move is coalesced. A board
                        // that needed a separate Apply press made the drag feel like it did
                        // nothing, and applying synchronously per drop froze it for seconds.
                        apply()
                    })
            }

            if !hider.lastArrangeFailures.isEmpty {
                consequenceBanner(
                    count: hider.lastArrangeFailures.count,
                    headline: hider.lastArrangeFailures.count == 1
                        ? "1 app could not be moved"
                        : "\(hider.lastArrangeFailures.count) apps could not be moved",
                    detail: hider.lastArrangeFailures.map {
                        $0.userMessage(displayName: Self.displayName(forBundleID:))
                    }.joined(separator: "\n"))
            }
            controlRow()
            systemSummary()
        }
    }

    /// One row's worth of app: its managed identity plus drawing data.
    private struct AppCandidate {
        let plan: ManagedAppCandidate
        let name: String
        let icon: NSImage?
        let isOnBarNow: Bool
    }

    /// Every app Stow can act on, decorated for the board.
    ///
    /// The LIST comes from `HideController.candidates`, not from a second walk here. This used to
    /// re-derive it: merge remembered homes with live positions, live winning, drop Stow's own
    /// bundle and Apple's, sort by home descending. That is the same algorithm the engine already
    /// had, extracted and unit-tested, and the two copies had drifted on two axes that both
    /// mattered:
    ///
    ///   - The Apple predicate. This copy excluded every `com.apple.*` bundle while the engine
    ///     excluded only `com.apple.controlcenter`. So an Apple extra the arranger CAN move, and
    ///     `com.apple.KerberosMenuExtra` was measured moving from x1153 to x1228, was never offered
    ///     a tile. Worse than an omission: `Config.zone(forBundleID:)` resolves a missing key to
    ///     `.pinned`, so the arranger acted on an implicit zone the user was never shown and had no
    ///     way to reverse.
    ///   - The stranded case. The engine lists an app that is pushed off the bar with no recorded
    ///     home at all, which is exactly OneDrive at x-8958: hidden before Stow's first walk ever
    ///     ran. This copy could not, and could not be fixed in place either, because `owners` is
    ///     populated from `BarItemOwners.claims()`, whose `x > 0` filter removes a stranded app by
    ///     construction.
    ///
    /// Both cases are pinned by tests the pane could not satisfy while it built its own list, so
    /// the suite was green and the shipped board disagreed with it.
    ///
    /// What is genuinely this function's own work is DECORATION: a name, an icon, a live width and
    /// whether the item is on the bar right now. None of that belongs in the engine, and all of it
    /// is looked up per candidate below.
    private func candidateApps() -> [AppCandidate] {
        // `identities()`, not `claims()`, for the same reason the engine uses it: a stranded app is
        // absent from `claims()` and it is a candidate. Cheap here because the walk is cached and
        // this pane has just refreshed it.
        let plans = HideController.candidates(identities: BarItemOwners.cachedIdentitiesList(),
                                              liveClaims: owners,
                                              homes: BarHomes.all,
                                              ownBundle: Bundle.main.bundleIdentifier)

        // Live items by bundle, so decoration can prefer a real measured width and a resolved icon
        // over anything remembered. Built once rather than searched per candidate.
        var liveByBundle: [String: ObservedItem] = [:]
        for item in (scan?.items ?? []).filter(\.isOnScreen) {
            guard let owner = item.owner(in: owners), !owner.bundleID.isEmpty else { continue }
            liveByBundle[owner.bundleID] = item
        }

        return plans.map { plan in
            let live = liveByBundle[plan.bundleID]
            let owner = live?.owner(in: owners)
            return AppCandidate(
                plan: plan,
                name: owner?.name ?? Self.displayName(forBundleID: plan.bundleID),
                icon: owner.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
                    ?? Self.icon(forBundleID: plan.bundleID),
                isOnBarNow: live != nil)
        }
    }

    /// A name for an app that is not currently claiming a bar item.
    ///
    /// Falls back through the running process, then the installed bundle on disk, then
    /// the identifier itself. The last of those is deliberately shown rather than
    /// replaced with "Unknown": a bundle identifier is at least actionable, and an app
    /// the user has since uninstalled should read as what it was, not as a mystery.
    private static func displayName(forBundleID bundleID: String) -> String {
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

    private static func icon(forBundleID bundleID: String) -> NSImage? {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first {
            return running.icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// A consequence stated loudly enough to be read.
    ///
    /// Replaces a line of small orange text below the board. That was accurate and it was
    /// ignored: an app the user never touched was hidden, and the only explanation sat further
    /// down the pane than the buttons. A tinted block with a headline is not decoration here,
    /// it is the difference between a warning and a surprise.
    private func consequenceBanner(count: Int, headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(StowTheme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StowTheme.ink)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StowTheme.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(StowTheme.orange.opacity(0.45), lineWidth: 1))
    }

    /// Changes apply from the board itself. This row reports that state and keeps only the
    /// everyday show/hide action, avoiding a second Apply button that suggests the drag did not
    /// already take effect.
    private func controlRow() -> some View {
        let nothingHidden = !store.config.hidesAnything
        let hiddenCount = candidateApps().filter {
            store.config.zone(forBundleID: $0.plan.bundleID) == .tucked
        }.count
        return HStack(spacing: 9) {
            if movingCut {
                ProgressView().controlSize(.small).tint(StowTheme.blue)
                Text("Updating the menu bar…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                Text(nothingHidden
                     ? "Drag an app into In Stow to begin."
                     : "Arrangement saved automatically")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
            }
            Spacer(minLength: 8)
            if !nothingHidden {
                Button(hider.presentation == .tidy
                       ? "Show \(hiddenCount) App\(hiddenCount == 1 ? "" : "s")"
                       : "Hide Again") {
                    hider.toggle()
                    Task { @MainActor in await rescan() }
                }
                .buttonStyle(.bordered)
                .disabled(movingCut)
                .help("Temporarily show or hide the apps assigned to In Stow")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    /// Apple's own items, collapsed to ONE line.
    ///
    /// They were previously listed individually alongside the apps, which was wrong twice
    /// over: Stow cannot address them individually, so they are not part of this decision at all,
    /// and six of them in the list buried the handful of apps that ARE the decision. One line
    /// states they exist and stay.
    ///
    /// Filters on `cannotBeAddressedIndividually`, NOT on `isApple`, and that matters now that the
    /// tile list above converged on the engine's candidate list. The engine excludes only
    /// `com.apple.controlcenter`, so an Apple extra like the Kerberos lock gets a draggable tile.
    /// While this filtered every `com.apple.*` bundle, the lock appeared BOTH as a tile the user can
    /// drag and in a line saying Stow does not offer to hide it. Two surfaces contradicting each
    /// other about the same icon is worse than either answer alone.
    ///
    /// Reads straight from the owners walk rather than the scan, because these are named
    /// per ITEM: macOS reports "Battery", "Clock", "Wi-Fi, connected, 3 bars" for what is
    /// otherwise six identical rows all reading "Control Center".
    private func systemSummary() -> some View {
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

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(StowTheme.inkSoft)
                .kerning(1.2)
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StowTheme.inkMuted)
            Rectangle().fill(StowTheme.hairline).frame(height: 1)
        }
    }
    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(StowTheme.inkMuted)
    }

    /// Applies the zones through the same transactional arranger used at launch.
    private func apply() {
        // COALESCE. One apply for a burst of drags, not one per drag.
        //
        // Zone changes are already saved and drawn the instant a tile is dropped, because the
        // board reads `store.config`. What costs time is moving the seams, and that work is
        // main-thread-bound: `NSStatusItem` cannot be touched off the main actor, so it cannot
        // be moved to a background queue to keep the UI live. Measured, one apply costs 3.3s to
        // 4.9s cold and 1.0s to 8.8s warm, dominated by the correction pass.
        //
        // So the fix is to run it FEWER times rather than faster. Dropping three tiles used to
        // queue three full applies, each re-measuring a bar the next one was about to change
        // again; now they settle into one. Re-zoning an app back and forth costs nothing extra.
        //
        // The board keeps accepting drops throughout: `isBusy` gates only the window in which
        // seams are actually moving, which is now one window per burst instead of one per drop.
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            // Long enough to absorb a run of drags, short enough that a single deliberate drag
            // does not feel deferred. A drag itself takes longer than this to perform.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            movingCut = true

            // MOVE THE APPS, not the seam.
            //
            // Measured on one bar, same zones, same run: the seam-moving path took 5.88s and
            // this took 0.79s, with zero apps on the wrong side either way. The saving is
            // structural rather than tuned: there is no placement slot to search for when the
            // seam does not move, and an app already on the correct side costs nothing.
            //
            // It also stops apps being swept by accident. A seam sweeps everything to its left,
            // so placing one to hide an app takes that app's neighbours with it, which is what
            // the pane's two collateral banners exist to apologise for. Measured during this
            // change, the first arrange MOVED `com.notebuddy.app` back onto the bar: it was
            // pinned, it had been swept, and nothing in the seam-moving path could recover it.
            //
            _ = hider.arrangeByMovingItems(from: store.config)
            // Reuse the walk the apply just took. See `rescan(reusingOwners:)`.
            await rescan(reusingOwners: true)
            movingCut = false
        }
    }

    /// - Parameter reusingOwners: when true, take the owner list from the cache instead of
    ///   walking every running application again.
    ///
    ///   The ownership walk is expensive, and the arranger has just refreshed the same cache.
    ///
    ///   Only safe straight after an apply. Positions in the cache go stale the moment the bar
    ///   reflows, and this method matches claims against live window frames within 4pt to decide
    ///   which items are visible, so a stale position records no home at all. Every other caller
    ///   leaves this false and walks.
    private func rescan(reusingOwners: Bool = false) async {
        guard let screen else { scan = nil; budget = nil; return }
        store.pruneUnavailableApps()
        let barRect = BarScanner.menuBarRect(for: screen)
        let notch = BarScanner.notchWidth(for: screen)
        let result = BarScanner.scan(menuBarRect: barRect)
        scan = result
        // ONE claims walk for the whole pane. `BarItemOwners.claims()` asks
        // every running application for its own `AXExtrasMenuBar`, which is
        // real work; calling it once here and resolving every row against
        // this same array is what keeps this pane cheap regardless of how
        // many items are on the bar.
        owners = reusingOwners && !BarItemOwners.lastKnownClaims.isEmpty
            ? BarItemOwners.lastKnownClaims
            : BarItemOwners.claims()

        // Remember where every VISIBLE item lives, and only while it is visible.
        //
        // This is what lets a hidden app still be listed, and listed in the right place:
        // a pushed item reports a position far off-screen that says nothing about where
        // it belongs. Recording only the on-screen ones is load-bearing, since recording
        // a pushed item would overwrite its real home with a meaningless number.
        let onScreenWindows = Set(result.items.filter(\.isOnScreen).map(\.windowNumber))
        let visibleClaims = owners.filter { claim in
            result.items.contains {
                onScreenWindows.contains($0.windowNumber)
                    && abs($0.frame.minX - claim.axLeftEdge) < 4
            }
        }
        BarHomes.record(visibleClaims)

        // Measured, like the panel and the Doctor. This was the THIRD place that
        // hardcoded both AX fields to zero; three surfaces quoting three different
        // budgets for one display is the failure this now avoids.
        let appMenus = MenuWidthProbe.measureFrontmostAppMenuWidth()
        let systemTrailing = MenuWidthProbe.measureSystemTrailingWidth()

        // Resolve Stow's seam first, because the budget below has to exclude it.
        seamWindows = hider.seamWindowNumbers()
        let seamIDs = seamWindows

        // EXCLUDE the seam from occupancy.
        //
        // While hiding, the seam is about 5,000pt wide, and counting that as consumed bar
        // space made the pane report "-3,470 pt headroom of 2,240 usable". The seam is not
        // an item competing for room; it IS the mechanism that makes room. Including it
        // measured the tool instead of the bar.
        budget = BarBudget(
            screenWidth: screen.frame.width,
            appMenuWidth: appMenus ?? 0,
            notchWidth: notch,
            systemTrailingWidth: systemTrailing ?? 0,
            occupiedWidths: result.items
                .filter(\.isOnScreen)
                .filter { !seamIDs.contains($0.windowNumber) }
                .map(\.frame.width))

    }
}

// MARK: - Profiles

/// The named profiles from design section 10, now driven by `Store` instead of a
/// local enum. The local `private enum Profile` this pane used to hold duplicated
/// `Config.Profile` (same four names, same four hotkeys, no way to ever diverge
/// from it), so it is gone; every row below reads `store.profiles` directly.
private struct ProfilesContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var hider: HideController
    @EnvironmentObject var ruleEngine: RuleEngine
    @State private var applyingProfileID: String?
    @State private var registeredShortcutCount = 0
    @State private var draftName = ""

    /// The id `AuroraMenu`'s selection binds to. `Config.Profile` is only
    /// `Equatable`, not `Hashable`, and `id` is also the exact field
    /// `Store.apply(_:)` persists, so keying the menu on it rather than on the
    /// whole struct needs no new conformance on `Config.Profile` at all.
    private var selectedID: String {
        store.activeProfile?.id ?? store.profiles.first?.id ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Profiles",
                           subtitle: "Switch the whole menu bar instantly or use Command-Shift-1…4.")

                CapabilityNote(
                    symbol: "bolt.fill",
                    label: "LIVE",
                    title: "Profile switching controls the real menu bar",
                    detail: "\(registeredShortcutCount) global shortcuts registered. Changes made"
                        + " in Arrange are saved to the active profile.")

                editorControls

                VStack(spacing: 8) {
                    ForEach(store.profiles) { profile in
                        profileButton(profile)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            store.ensureProfileLayouts(candidateOrder: candidateOrder)
            registeredShortcutCount = ProfileHotKeys.shared.registeredCount
            draftName = activeProfile?.name ?? ""
        }
        .onChange(of: selectedID) { _, _ in
            draftName = activeProfile?.name ?? ""
        }
    }

    private var candidateOrder: [String] {
        hider.currentCandidates().map(\.bundleID)
    }

    private var activeProfile: Config.Profile? {
        store.profiles.first { $0.id == selectedID }
    }

    private var editorControls: some View {
        HStack(spacing: 8) {
            TextField("Profile name", text: $draftName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: 240)
                .background(Aurora.inset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StowTheme.hairline))
                .onSubmit { renameActive() }
            Button("Rename") { renameActive() }
                .buttonStyle(.bordered)
                .disabled(activeProfile == nil || draftName.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            Button("Save Current", systemImage: "square.and.arrow.down") {
                guard let activeProfile else { return }
                store.saveCurrentLayout(profileID: activeProfile.id,
                                        candidateOrder: candidateOrder)
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Menu {
                Button("New Profile", systemImage: "plus") { createProfile() }
                Button("Duplicate Active", systemImage: "plus.square.on.square") {
                    duplicateActive()
                }
                if let activeProfile,
                   !Store.builtInProfileIDs.contains(activeProfile.id) {
                    Divider()
                    Button("Delete Active", systemImage: "trash", role: .destructive) {
                        deleteActive()
                    }
                }
            } label: {
                Label("Profile Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func profileButton(_ profile: Config.Profile) -> some View {
        let active = profile.id == selectedID
        return Button {
            apply(profile)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(active
                          ? AnyShapeStyle(StowTheme.diagonal(for: .tidy).opacity(0.22))
                          : AnyShapeStyle(Aurora.inset))
                    .frame(width: 36, height: 36)
                    .overlay {
                        if applyingProfileID == profile.id {
                            ProgressView().controlSize(.small).tint(StowTheme.blue)
                        } else {
                            Image(systemName: profileSymbol(profile))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(active
                                                 ? (StowTheme.stops(for: .tidy).first
                                                    ?? StowTheme.blue)
                                                 : StowTheme.inkSoft)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(profile.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StowTheme.ink)
                        if active {
                            Text("ACTIVE")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .kerning(0.8)
                                .foregroundStyle(StowTheme.stops(for: .tidy).first
                                                 ?? StowTheme.blue)
                        }
                    }
                    Text(profileDetail(profile))
                        .font(.system(size: 10.5))
                        .foregroundStyle(StowTheme.inkMuted)
                }
                Spacer(minLength: 8)
                Text(profile.hotkeyDisplay.isEmpty ? "CUSTOM" : profile.hotkeyDisplay)
                    .font(.system(size: profile.hotkeyDisplay.isEmpty ? 8.5 : 10.5,
                                  weight: .semibold, design: .monospaced))
                    .kerning(profile.hotkeyDisplay.isEmpty ? 0.7 : 0)
                    .foregroundStyle(StowTheme.inkSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Aurora.inset, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StowTheme.hairline))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? StowTheme.cardHover : StowTheme.card,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active
                              ? (StowTheme.stops(for: .tidy).first ?? StowTheme.blue).opacity(0.38)
                              : StowTheme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(applyingProfileID != nil)
        .accessibilityLabel("Apply \(profile.name) profile")
        .accessibilityValue(active ? "Active" : profileDetail(profile))
    }

    private func apply(_ profile: Config.Profile) {
        applyingProfileID = profile.id
        ruleEngine.noteManualSelection()
        Task { @MainActor in
            await Task.yield()
            let previous = store.config
            let updated = store.apply(profile, candidateOrder: candidateOrder)
            let outcome = hider.arrangeByMovingItems(from: updated)
            if !outcome.isClean { store.config = previous }
            applyingProfileID = nil
        }
    }

    private func profileDetail(_ profile: Config.Profile) -> String {
        let hidden = profile.appZones?.values.filter { $0 == .tucked }.count ?? 0
        if hidden == 0 { return "Everything visible" }
        return "\(hidden) app\(hidden == 1 ? "" : "s") in Stow"
    }

    private func profileSymbol(_ profile: Config.Profile) -> String {
        switch profile.id {
        case "presenting": return "rectangle.on.rectangle.slash"
        case "screen-share": return "rectangle.inset.filled.and.person.filled"
        case "focus": return "scope"
        case "everything": return "eye.fill"
        default: return "square.stack.3d.up.fill"
        }
    }

    private func renameActive() {
        guard let activeProfile else { return }
        store.renameProfile(id: activeProfile.id, name: draftName)
    }

    private func createProfile() {
        ruleEngine.noteManualSelection()
        let profile = store.createProfile(name: "New Profile", candidateOrder: candidateOrder)
        draftName = profile.name
    }

    private func duplicateActive() {
        guard let activeProfile else { return }
        ruleEngine.noteManualSelection()
        if let copy = store.duplicateProfile(id: activeProfile.id) {
            draftName = copy.name
        }
    }

    private func deleteActive() {
        guard let activeProfile else { return }
        ruleEngine.noteManualSelection()
        let nextID = store.deleteProfile(id: activeProfile.id)
        guard let nextID,
              let next = store.profiles.first(where: { $0.id == nextID }) else { return }
        draftName = next.name
        apply(next)
    }
}

// MARK: - Rules

/// Design section 10's shape for a rule, driven by `Store` rather than the two
/// hardcoded example cards this pane used to show. There is still no rules
/// engine to author or evaluate a condition against, so this pane stays
/// read-only, but what it lists is now exactly what `Config.rules` persists,
/// not illustrative text that never matched what was actually saved.
private struct RulesContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ruleEngine: RuleEngine
    @State private var selectedBundleID = ""
    @State private var selectedProfileID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Rules",
                       subtitle: "Let context choose the right menu-bar layout for you.")

            CapabilityNote(symbol: "wand.and.stars",
                           label: ruleEngine.activeRuleID == nil ? "LIVE" : "ACTIVE",
                           title: "Frontmost-app automation is running",
                           detail: ruleEngine.lastStatus)

            HStack(spacing: 9) {
                AuroraMenu(options: appOptions,
                           selection: $selectedBundleID,
                           placeholder: "Choose app")
                Image(systemName: "arrow.right")
                    .foregroundStyle(StowTheme.inkMuted)
                AuroraMenu(options: profileOptions,
                           selection: $selectedProfileID,
                           placeholder: "Choose profile")
                Spacer(minLength: 8)
                Button("Add Rule", systemImage: "plus") { addRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedBundleID.isEmpty || selectedProfileID.isEmpty)
            }

            if store.rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 22))
                        .foregroundStyle(StowTheme.inkMuted)
                    Text("No rules yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StowTheme.ink)
                    Text("Choose a running app and the profile Stow should apply.")
                        .font(.system(size: 11))
                        .foregroundStyle(StowTheme.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StowTheme.hairline))
            } else {
                VStack(spacing: 8) {
                    ForEach(store.rules) { rule in
                        ruleCard(rule)
                    }
                }
            }
        }
        .padding(24)
        .onAppear {
            if selectedBundleID.isEmpty { selectedBundleID = appOptions.first?.value ?? "" }
            if selectedProfileID.isEmpty {
                selectedProfileID = store.activeProfile?.id ?? store.profiles.first?.id ?? ""
            }
        }
    }

    private func ruleCard(_ rule: Config.Rule) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(ruleEngine.activeRuleID == rule.id
                      ? StowTheme.blue.opacity(0.16) : Aurora.inset)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "app.badge.checkmark")
                    .foregroundStyle(ruleEngine.activeRuleID == rule.id
                                     ? StowTheme.blue : StowTheme.inkSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(describe(rule.condition))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(rule.isEnabled ? StowTheme.ink : StowTheme.inkMuted)
                Text(describe(rule.action))
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { rule.isEnabled },
                set: { store.setRule(id: rule.id, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(AuroraToggleStyle())
            Button("Delete", systemImage: "trash") { store.removeRule(id: rule.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(StowTheme.inkMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StowTheme.hairline))
    }

    private func describe(_ condition: Config.Rule.Condition) -> String {
        switch condition {
        case .screenSharingStarted: return "Screen sharing starts"
        case .screenSharingEnded: return "Screen sharing ends"
        case .frontmostAppIs(let bundleID): return "When \(displayName(bundleID)) is frontmost"
        }
    }

    private func describe(_ action: Config.Rule.Action) -> String {
        switch action {
        case .applyProfile(let id):
            let name = store.profiles.first(where: { $0.id == id })?.name ?? id
            return "Apply \(name), then restore the previous profile on exit"
        case .revealTuckedSlot(let depth): return "Reveal tucked slot \(depth)"
        case .tuckPinnedSlot(let depth): return "Tuck pinned slot \(depth)"
        }
    }

    private var appOptions: [(value: String, label: String, shortcut: String?)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (value: String, label: String, shortcut: String?)? in
                guard let bundleID = app.bundleIdentifier,
                      bundleID != Bundle.main.bundleIdentifier,
                      seen.insert(bundleID).inserted else { return nil }
                return (bundleID, app.localizedName ?? bundleID, nil)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var profileOptions: [(value: String, label: String, shortcut: String?)] {
        store.profiles.map { ($0.id, $0.name, $0.hotkeyDisplay) }
    }

    private func addRule() {
        for existing in store.rules {
            if case .frontmostAppIs(let bundleID) = existing.condition,
               bundleID == selectedBundleID {
                store.removeRule(id: existing.id)
            }
        }
        store.addRule(.init(
            id: "frontmost:\(selectedBundleID)",
            isEnabled: true,
            condition: .frontmostAppIs(bundleID: selectedBundleID),
            action: .applyProfile(id: selectedProfileID)))
    }

    private func displayName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { FileManager.default.displayName(atPath: $0.path) }
            ?? bundleID
    }
}

// MARK: - Settings

/// Design section 10: hotkeys, reveal-on-hover, auto-tuck delay, launch at login.
///
/// Reveal on hover and auto-tuck delay now persist through `Store`, which did not
/// exist when this pane was first written. Persisting is not the same as acting:
/// there is still no reveal engine to read either value back, so this pane must
/// not claim reveal-on-hover does anything on the bar yet, only that the choice is
/// remembered. Launch at login stays the one control backed by a real system API:
/// `SMAppService.mainApp.status` is live OS state, not a preference, so its
/// display always reads the actual status while the user's last request is also
/// recorded in `Store` for anything that later wants to know intent rather than
/// current state. Hotkeys still need a hotkey manager that does not exist yet.
private struct SettingsContentView: View {
    @EnvironmentObject var store: Store
    /// The system's ACTUAL registration state, read once and updated only after
    /// `SMAppService` accepts a change. Never derived from `store.config`: a
    /// config value is what the user asked for, not what macOS is currently
    /// doing, and those two can disagree (a registration silently revoked
    /// outside the app, for one).
    @State private var launchAtLoginActual = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader(title: "Settings",
                           subtitle: "Tune the parts of Stow that are active today.")

                settingsSection("HIDDEN APP MENUS") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Return to Stow after")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(StowTheme.ink)
                        Text("How long a temporarily opened app remains visible.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                    Spacer()
                    AuroraStepper(value: Binding(
                        get: { store.config.revealDuration },
                        set: { store.config.revealDurationSeconds = $0 }
                    ), range: 5...60, step: 5,
                       format: { "\(Int($0))s" },
                       accessibilityName: "Return to Stow delay")
                }
            }

            settingsSection("RECOVERY") {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(StowTheme.diagonal(for: .tidy).opacity(0.18))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: "eye.fill")
                            .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show everything")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(StowTheme.ink)
                        Text("Immediately returns every hidden app to the menu bar.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                    Spacer()
                    Text("⌘⇧Esc")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StowTheme.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Aurora.inset, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(StowTheme.hairline))
                }
            }

            settingsSection("GENERAL") {
                Toggle("Launch Stow at login", isOn: Binding(
                    get: { launchAtLoginActual },
                    set: { newValue in
                        loginError = nil
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLoginActual = newValue
                            store.config.launchAtLogin = newValue
                        } catch {
                            loginError = "Could not \(newValue ? "enable" : "disable"):"
                                + " \(error.localizedDescription)"
                        }
                    }
                ))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(StowTheme.ink)
                .toggleStyle(AuroraToggleStyle())
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(StowTheme.orange)
                }
            }

            settingsSection("ABOUT") {
                HStack {
                    Image(nsImage: StowGlyph.image(for: .tidy, size: NSSize(width: 28, height: 28),
                                                   glow: false))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stow \(StowVersion.current)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(StowTheme.ink)
                        Text(StowVersion.builderAttribution)
                            .font(.system(size: 10.5))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                    Spacer()
                    Text(StowVersion.buildCommit.prefix(7))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StowTheme.inkMuted)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(StowTheme.sweep(for: .tidy))
                    .kerning(1.2)
                Rectangle().fill(StowTheme.hairline).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StowTheme.hairline))
        }
    }
}

// MARK: - Shared

private struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(StowTheme.inkSoft)
        }
    }
}

private struct CapabilityNote: View {
    let symbol: String
    let label: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 8)
                .fill(StowTheme.blue.opacity(0.10))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StowTheme.blue))
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .kerning(1.1)
                    .foregroundStyle(StowTheme.blue)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(StowTheme.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(StowTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(StowTheme.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(StowTheme.blue.opacity(0.18)))
    }
}

/// A visible, honest note that the engine behind a rendered surface is not yet
/// wired. Used across Arrange, Profiles, Rules and Settings rather than a silent
/// stub or a blank pane, per this stage's own instruction: render the real
/// surface, then say plainly what does not act on it yet.
private struct NotYetWiredBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11))
                .foregroundStyle(StowTheme.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(StowTheme.inkSoft)
        }
        .padding(12)
        .background(StowTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StowTheme.orange.opacity(0.25)))
    }
}

// MARK: - NSScreen identity

extension NSScreen {
    /// The receiver's `CGDirectDisplayID`, recovered from its device description.
    ///
    /// `NSScreen` itself is not a stable identity across the display's own
    /// reconfiguration: sleep/wake and resolution changes can hand back a new
    /// `NSScreen` instance for the same physical panel. The display picker and
    /// both Doctor checks that take a screen key off this integer instead, so a
    /// picker selection survives a reconfiguration that would otherwise silently
    /// point at a stale object.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
