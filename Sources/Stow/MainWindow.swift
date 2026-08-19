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
/// Three of the six destinations below front a subsystem this PLAN 0 stage does
/// not build: dragging a tile between zones needs a persisted store and a spacer
/// status item that PLAN A builds, and per-key hotkeys need a hotkey manager
/// that PLAN A also builds. Those destinations still render their real surface
/// (the measured bar, the four named profiles, the two worked-example rules),
/// with a visible note that the engine behind them is not yet wired, rather
/// than a blank pane or a silent stub. The Doctor destination is the one place
/// in this file where every check is real today.
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
        .frame(minWidth: 760, idealWidth: 840, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
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
            await doctor.run(screen: selectedScreen)
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
                // A picker offering exactly one choice is not a choice; naming the
                // single attached display plainly is more honest than a dead
                // dropdown that always opens to one row.
                Text(selectedScreen?.localizedName ?? "No display")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var displayOptions: [(value: CGDirectDisplayID, label: String, shortcut: String?)] {
        NSScreen.screens.map { ($0.displayID, $0.localizedName, nil) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("LAYOUT", Destination.layout)
            group("HEALTH", Destination.health)
            group("APP", Destination.app)
            Spacer(minLength: 12)
            utilities
        }
        .frame(width: 186)
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
                Text(dest.glyph)
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
        case .profiles:
            return (Config.defaultProfiles.count, false)
        case .doctor:
            let n = doctor.warnCount
            return n > 0 ? (n, true) : nil
        default:
            return nil
        }
    }

    private var utilities: some View {
        HStack(spacing: 10) {
            Button {
                Task { await doctor.run(screen: selectedScreen) }
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
        static let health: [Destination] = [.doctor, .whatsNew]
        static let app: [Destination] = [.settings]

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

        /// The mock's own glyphs, rendered as text rather than SF Symbols because
        /// the design specifies these exact characters, not a systemName.
        var glyph: String {
            switch self {
            case .arrange:  return "◫"
            case .profiles: return "▣"
            case .rules:    return "⇄"
            case .doctor:   return "⚗"
            case .whatsNew: return "✨"
            case .settings: return "⚙"
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
    /// Where the seam sits, measured.
    @State private var cutX: CGFloat?
    /// True while a cut move is searching for a slot, so the pane can disable its
    /// controls rather than queue several searches on top of each other.
    @State private var movingCut = false
    /// The pending coalesced apply, so a burst of drags cancels its predecessor rather than
    /// queueing another full seam move behind it. See `apply(outcome:)`.
    @State private var applyTask: Task<Void, Never>?
    /// Why the last arrange could not place an app, if it could not.
    ///
    /// Surfaced rather than swallowed. A move is a synthesised drag and the OS can refuse one,
    /// so an app can silently stay on the wrong side; showing nothing would leave the user
    /// re-dragging a tile that Stow had already given up on.
    @State private var arrangeFailures: [String] = []
    /// Stow's seam window number, so it is excluded from occupancy arithmetic.
    @State private var seamWindows: Set<CGWindowID> = []


    var body: some View {
        // Scrollable, because it is not: on a 16 item bar the list ran past the
        // bottom of the window with no way to reach the rest of it, and the header
        // and footer went with it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                explanation
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
            if let budget {
                Text("\(Int(budget.headroom)) pt headroom of \(Int(budget.usable)) usable")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StowTheme.inkMuted)
            } else {
                Text("measuring…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StowTheme.inkMuted)
            }
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
        let outcome = BarPlan.outcome(candidates: candidates.map(\.plan),
                                      zones: { store.config.zone(forBundleID: $0) },
                                      placementFloor: hider.placementFloor)
        let collateral = Set(outcome.collateral)
        let belowFloor = Set(outcome.belowPlacementFloor)

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
                            widthPt: candidate.widthPt,
                            isOnBarNow: candidate.isOnBarNow,
                            isCollateral: collateral.contains(candidate.plan.bundleID),
                            isBelowFloor: belowFloor.contains(candidate.plan.bundleID))
                    },
                    zoneOf: { store.config.zone(forBundleID: $0) },
                    onMove: { bundle, zone in
                        store.config.setZone(zone, forBundleID: bundle)
                        // The zone is saved and drawn NOW; the seam move is coalesced. A board
                        // that needed a separate Apply press made the drag feel like it did
                        // nothing, and applying synchronously per drop froze it for seconds.
                        apply(outcome: outcome)
                    })
            }

            // The consequences BEFORE the buttons, not after. They were below the board and
            // read as a footnote, which is how an app the user never touched came to be hidden
            // with the explanation off the bottom of the pane.
            //
            if !arrangeFailures.isEmpty {
                consequenceBanner(
                    count: arrangeFailures.count,
                    headline: arrangeFailures.count == 1
                        ? "1 app could not be moved"
                        : "\(arrangeFailures.count) apps could not be moved",
                    detail: "macOS refused the move. Try again, and if it keeps failing,"
                        + " command-drag the app across Stow's icon by hand."
                        + " Details: " + arrangeFailures.joined(separator: "; "))
            }
            applyRow(outcome: outcome)
            systemSummary()
        }
    }

    /// Legacy row renderer retained for compact layouts.
    private func zoneRow(_ candidate: AppCandidate,
                         isCollateral: Bool,
                         hiddenAtRest: Bool) -> some View {
        let bundle = candidate.plan.bundleID
        let zone = store.config.zone(forBundleID: bundle)

        return HStack(spacing: 9) {
            if let icon = candidate.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    .opacity(hiddenAtRest ? 0.45 : 1)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(StowTheme.inkMuted)
                    .frame(width: 16, height: 16)
            }
            Text(candidate.name)
                .font(.system(size: 11.5))
                .foregroundStyle(hiddenAtRest ? StowTheme.inkSoft : StowTheme.ink)
                .lineLimit(1)
            if let width = candidate.widthPt {
                Text("\(Int(width)) pt")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
            }
            Spacer(minLength: 8)

            if isCollateral {
                Text("hidden anyway")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StowTheme.orange)
                    .help("Sits left of a seam your other choices require."
                          + " Command-drag it right of that seam in the menu bar to keep it.")
            } else if !candidate.isOnBarNow {
                Text("off the bar")
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
            }

            Picker("", selection: Binding(
                get: { zone },
                set: { store.config.setZone($0, forBundleID: bundle) })) {
                    Text("On Bar").tag(Zone.pinned)
                    Text("In Stow").tag(Zone.tucked)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(movingCut)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    /// One row's worth of app: the planning facts plus what it takes to draw it.
    ///
    /// Split this way so `BarPlan` stays pure and testable: it only ever sees
    /// `BarPlan.Candidate`, never an icon or a display name.
    private struct AppCandidate {
        let plan: BarPlan.Candidate
        let name: String
        let icon: NSImage?
        /// Live width, when the item is currently on the bar. Nil for a hidden app,
        /// because its width is not measurable while it is pushed and a remembered one
        /// would go stale as the app's own state changes.
        let widthPt: CGFloat?
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
                widthPt: live?.frame.width,
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

    /// Explains the placement floor, which is a macOS limit rather than a Stow choice.
    ///
    /// Worth its own note rather than folding into the others, because the fix is different:
    /// the other warnings are resolved by changing a zone, this one only by physically moving
    /// the icon.
    private func floorNote(count: Int) -> some View {
        Text("\(count) app\(count == 1 ? " sits" : "s sit") further left than macOS lets Stow"
             + " place a seam, so \(count == 1 ? "it" : "they") cannot be split into"
             + " different zones from each other. Command-drag"
             + " \(count == 1 ? "it" : "them") to the right in the menu bar to zone"
             + " \(count == 1 ? "it" : "them") separately.")
            .font(.system(size: 10.5))
            .foregroundStyle(StowTheme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Applies the zones, and offers the reveal.
    ///
    /// Apply plus the everyday open/close action.
    private func applyRow(outcome: BarPlan.Outcome) -> some View {
        let nothingHidden = outcome.tuckedBoundaryX == nil
        let unsafe = !outcome.isSafeToApply
        return HStack(spacing: 10) {
            Button(unsafe ? "Unavailable app" : (nothingHidden ? "Show everything" : "Apply")) {
                apply(outcome: outcome)
            }
            .disabled(movingCut || unsafe)

            Button(hider.presentation == .revealed ? "Close Stow" : "Open Stow") {
                hider.toggle()
                Task { @MainActor in await rescan() }
            }
            .disabled(movingCut || nothingHidden || unsafe)
            .help("Temporarily returns apps in Stow to the menu bar")

            if movingCut {
                ProgressView().controlSize(.small).tint(StowTheme.blue)
            }
            Text(seamSummary(outcome))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(StowTheme.inkMuted)
        }
        .padding(.top, 4)
    }

    /// Where the boundary is, in one line.
    private func seamSummary(_ outcome: BarPlan.Outcome) -> String {
        cutX.map { "boundary x\(Int($0))" } ?? "boundary not placed"
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(system.count) system items")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(StowTheme.inkSoft)
                    Text("Stow cannot offer these one at a time. macOS reports all of them as"
                         + " Control Center, and Stow arranges by app, so they would only ever"
                         + " move together.")
                        .font(.system(size: 10))
                        .foregroundStyle(StowTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(system.map(\.name).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(StowTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
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

    /// Applies the zones to the real bar.
    ///
    /// Delegates to `HideController.applyPersistedPlan`, which is the SAME path the app runs
    /// at launch. Duplicating the placement logic here is how the two drifted apart once
    /// already: the launch path gained a re-measure between the two seam placements and this
    /// one did not, so applying from the pane produced a different bar than relaunching did.
    private func apply(outcome: BarPlan.Outcome) {
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
            let outcome = hider.arrangeByMovingItems(from: store.config)
            arrangeFailures = outcome.failed.map {
                $0.userMessage(displayName: Self.displayName(forBundleID:))
            }
            cutX = hider.measuredCutX()

            // Reuse the walk the apply just took. See `rescan(reusingOwners:)`.
            await rescan(reusingOwners: true)
            movingCut = false
        }
    }

    /// - Parameter reusingOwners: when true, take the owner list from the cache instead of
    ///   walking every running application again.
    ///
    ///   The walk is the single most expensive thing this pane does, measured at 0.965s, and a
    ///   drag was paying for THREE of them: one in `applyPersistedPlan` to record homes, one in
    ///   `correctPlacementIfWrong` to check what actually got hidden, and one here. The last two
    ///   see the same bar, because the correction leaves the cache describing the final state,
    ///   so walking again here bought nothing and cost a second of a frozen board.
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

        cutX = hider.measuredCutX()
    }
}

// MARK: - Profiles

/// The named profiles from design section 10, now driven by `Store` instead of a
/// local enum. The local `private enum Profile` this pane used to hold duplicated
/// `Config.Profile` (same four names, same four hotkeys, no way to ever diverge
/// from it), so it is gone; every row below reads `store.profiles` directly.
private struct ProfilesContentView: View {
    @EnvironmentObject var store: Store

    /// The id `AuroraMenu`'s selection binds to. `Config.Profile` is only
    /// `Equatable`, not `Hashable`, and `id` is also the exact field
    /// `Store.apply(_:)` persists, so keying the menu on it rather than on the
    /// whole struct needs no new conformance on `Config.Profile` at all.
    private var selectedID: String {
        store.activeProfile?.id ?? store.profiles.first?.id ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Profiles")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)

            NotYetWiredBanner(text: "Applying a profile does not move anything"
                + " between zones yet: that needs a reveal engine that does not exist."
                + " The menu below is real and persists through the Store, so your"
                + " selection survives closing this window; it simply has nothing"
                + " downstream to act on yet.")

            AuroraMenu(
                options: store.profiles.map { ($0.id, $0.name, $0.hotkeyDisplay) },
                selection: Binding(
                    get: { selectedID },
                    set: { newID in
                        guard let profile = store.profiles.first(where: { $0.id == newID })
                        else { return }
                        store.apply(profile)
                    }
                ))

            VStack(spacing: 6) {
                ForEach(store.profiles) { profile in
                    HStack {
                        Text(profile.name)
                            .font(.system(size: 12.5))
                            .foregroundStyle(profile.id == selectedID
                                             ? StowTheme.ink : StowTheme.inkSoft)
                        Spacer()
                        Text(profile.hotkeyDisplay)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(profile.id == selectedID ? StowTheme.card : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(20)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rules")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)

            NotYetWiredBanner(text: "There is no rules engine yet: nothing below"
                + " actually watches screen sharing or the frontmost app. This list is"
                + " read-only and shows exactly what the Store has persisted, which is"
                + " the shape a rule will take once one can be authored and evaluated.")

            if store.rules.isEmpty {
                Text("No rules saved yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StowTheme.inkMuted)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.rules) { rule in
                        ruleCard(rule)
                    }
                }
            }
        }
        .padding(20)
    }

    private func ruleCard(_ rule: Config.Rule) -> some View {
        HStack(spacing: 10) {
            Text(describe(rule.condition))
                .font(.system(size: 12))
                .foregroundStyle(rule.isEnabled ? StowTheme.ink : StowTheme.inkMuted)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StowTheme.inkMuted)
            Text(describe(rule.action))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(rule.isEnabled
                                 ? AnyShapeStyle(StowTheme.sweep(for: .tidy))
                                 : AnyShapeStyle(StowTheme.inkMuted))
            if !rule.isEnabled {
                Spacer(minLength: 0)
                Text("disabled")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
            }
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
        case .frontmostAppIs(let bundleID): return "\(bundleID) is frontmost"
        }
    }

    private func describe(_ action: Config.Rule.Action) -> String {
        switch action {
        case .applyProfile(let id): return "Apply profile \"\(id)\""
        case .revealTuckedSlot(let depth): return "Reveal tucked slot \(depth)"
        case .tuckPinnedSlot(let depth): return "Tuck pinned slot \(depth)"
        }
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
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(StowTheme.ink)

            settingsSection("HOTKEYS") {
                NotYetWiredBanner(text: "Hotkey registration needs a hotkey manager,"
                    + " which is PLAN A and does not exist yet. Nothing here can be"
                    + " bound to a key until it lands.")
            }

            settingsSection("BEHAVIOR") {
                Toggle("Reveal on hover", isOn: Binding(
                    get: { store.revealOnHoverEnabled },
                    set: { store.config.revealOnHover = $0 }
                ))
                    .toggleStyle(AuroraToggleStyle())
                HStack {
                    Text("Auto-tuck delay")
                        .font(.system(size: 12.5))
                        .foregroundStyle(StowTheme.ink)
                    Spacer()
                    AuroraStepper(value: Binding(
                        get: { store.autoTuckDelay },
                        set: { store.config.autoTuckDelaySeconds = $0 }
                    ), range: 1...15, step: 1,
                       format: { "\(Int($0))s" },
                       accessibilityName: "Auto-tuck delay")
                }
                Text("Both settings above now persist through the Store and survive"
                     + " closing this window. Reveal on hover still does nothing on"
                     + " the bar itself: there is no reveal engine to read it back yet,"
                     + " so it holds your choice and waits.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkMuted)
            }

            settingsSection("LOGIN") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginActual },
                    set: { newValue in
                        loginError = nil
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            // Only commit the new value once macOS has actually
                            // accepted the request. Setting it optimistically and
                            // reverting on failure inside the same setter would
                            // fire this Binding's setter a second time, which is
                            // both unnecessary and the shape of the exact
                            // re-entrancy bug this avoids by never assigning
                            // twice.
                            launchAtLoginActual = newValue
                            // The user's INTENT, recorded alongside the live status
                            // above rather than instead of it, so a future reader
                            // can tell "what was last requested" from "what macOS
                            // is doing right now" without conflating the two.
                            store.config.launchAtLogin = newValue
                        } catch {
                            loginError = "Could not \(newValue ? "enable" : "disable"):"
                                + " \(error.localizedDescription)"
                        }
                    }
                ))
                .toggleStyle(AuroraToggleStyle())
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(StowTheme.orange)
                }
            }
        }
        .padding(20)
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
            content()
        }
    }
}

// MARK: - Shared

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
