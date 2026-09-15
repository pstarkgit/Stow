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
/// forward-only arranger. Rules remains an explicit preview until its context evaluator ships.
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
    @EnvironmentObject private var ruleEngine: RuleEngine

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
                             seamWindows: hider.seamWindowNumbers(),
                             profileHotKeyCount: ProfileHotKeys.shared.registeredCount,
                             automationRunning: ruleEngine.isRunning)
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
                                     seamWindows: hider.seamWindowNumbers(),
                                     profileHotKeyCount: ProfileHotKeys.shared.registeredCount,
                                     automationRunning: ruleEngine.isRunning)
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
        hider.currentCandidates(config: store.config).map(\.bundleID)
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
        ruleEngine.noteManualSelection(selectedProfileID: profile.id)
        Task { @MainActor in
            await Task.yield()
            let updated = store.apply(profile, candidateOrder: candidateOrder)
            // A profile is a boundary width. Switching one cannot be refused by macOS and
            // never touches the pointer.
            hider.applyProfile(peek: profile.tuckedRunDepth, config: updated)
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
        case "presenting": return "house.fill"
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
        let profile = store.createProfile(name: "New Profile", candidateOrder: candidateOrder)
        ruleEngine.noteManualSelection(selectedProfileID: profile.id)
        draftName = profile.name
    }

    private func duplicateActive() {
        guard let activeProfile else { return }
        if let copy = store.duplicateProfile(id: activeProfile.id) {
            ruleEngine.noteManualSelection(selectedProfileID: copy.id)
            draftName = copy.name
        }
    }

    private func deleteActive() {
        guard let activeProfile else { return }
        let nextID = store.deleteProfile(id: activeProfile.id)
        guard let nextID,
              let next = store.profiles.first(where: { $0.id == nextID }) else { return }
        ruleEngine.noteManualSelection(selectedProfileID: next.id)
        draftName = next.name
        apply(next)
    }
}

// MARK: - Rules

/// Live frontmost-application rules backed by `RuleEngine` and persisted in `Store`.
private struct RulesContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ruleEngine: RuleEngine
    @State private var selectedBundleID = ""
    @State private var selectedProfileID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: "Rules",
                           subtitle: "Let context choose the right menu-bar layout for you.")

                CapabilityNote(symbol: "wand.and.stars",
                               label: ruleEngine.activeRuleID == nil ? "LIVE" : "ACTIVE",
                               title: "Frontmost-app automation is running",
                               detail: ruleEngine.activeReason)

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

                if !Store.conflictingRuleIDs(in: store.rules).isEmpty {
                    conflictBanner
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

                if !ruleEngine.activities.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionKicker("AUTOMATION ACTIVITY")
                        ForEach(ruleEngine.activities.prefix(8)) { activity in
                            activityRow(activity)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if selectedBundleID.isEmpty { selectedBundleID = appOptions.first?.value ?? "" }
            if selectedProfileID.isEmpty {
                selectedProfileID = store.activeProfile?.id ?? store.profiles.first?.id ?? ""
            }
        }
    }

    private func ruleCard(_ rule: Config.Rule) -> some View {
        let index = store.rules.firstIndex(where: { $0.id == rule.id }) ?? 0
        let conflicts = Store.conflictingRuleIDs(in: store.rules)
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(ruleEngine.activeRuleID == rule.id
                      ? StowTheme.blue.opacity(0.16) : Aurora.inset)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "app.badge.checkmark")
                    .foregroundStyle(ruleEngine.activeRuleID == rule.id
                                     ? StowTheme.blue : StowTheme.inkSoft))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("P\(index + 1)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(StowTheme.blue)
                    Text(describe(rule.condition))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(rule.isEnabled ? StowTheme.ink : StowTheme.inkMuted)
                    if conflicts.contains(rule.id) {
                        Text("CONFLICT")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(StowTheme.orange)
                    }
                }
                Text(describe(rule.action))
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
            }
            Spacer(minLength: 8)
            VStack(spacing: 1) {
                Button("Move up", systemImage: "chevron.up") {
                    store.moveRule(id: rule.id, by: -1)
                }
                .disabled(index == 0)
                Button("Move down", systemImage: "chevron.down") {
                    store.moveRule(id: rule.id, by: 1)
                }
                .disabled(index == store.rules.count - 1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(StowTheme.inkMuted)
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
        store.addRule(.init(
            id: "frontmost:\(selectedBundleID):\(UUID().uuidString.lowercased())",
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

    private func activityRow(_ activity: RuleEngine.Activity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activitySymbol(activity.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activityTint(activity.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StowTheme.ink)
                Text(activity.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(activityAge(activity.timestamp))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(StowTheme.inkMuted)
            if let ruleID = activity.ruleID,
               store.rules.contains(where: { $0.id == ruleID && $0.isEnabled }) {
                Button("Disable rule") { store.setRule(id: ruleID, isEnabled: false) }
                    .font(.system(size: 9.5, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(StowTheme.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Aurora.inset, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StowTheme.hairline))
    }

    private func activitySymbol(_ kind: RuleEngine.Activity.Kind) -> String {
        switch kind {
        case .applied: return "bolt.fill"
        case .restored: return "arrow.uturn.backward"
        case .failed: return "exclamationmark.triangle.fill"
        case .manualOverride: return "hand.raised.fill"
        case .cooldown: return "timer"
        }
    }

    private func activityTint(_ kind: RuleEngine.Activity.Kind) -> Color {
        switch kind {
        case .applied, .restored: return StowTheme.stops(for: .tidy).first ?? StowTheme.blue
        case .failed: return StowTheme.orange
        case .manualOverride, .cooldown: return StowTheme.blue
        }
    }

    private func activityAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    private var conflictBanner: some View {
        let count = Store.conflictingRuleIDs(in: store.rules).count
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StowTheme.orange)
            Text("\(count) enabled rules share an application trigger. The highest priority wins.")
                .font(.system(size: 10.5))
                .foregroundStyle(StowTheme.inkSoft)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StowTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(StowTheme.orange.opacity(0.28)))
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

private struct SectionKicker: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(StowTheme.sweep(for: .tidy))
            Rectangle().fill(StowTheme.hairline).frame(height: 1)
        }
    }
}

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
