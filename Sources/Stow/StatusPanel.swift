import SwiftUI
import AppKit

/// Stow's compact menu-bar command surface.
///
/// Hidden apps are the primary content because they are the only bar items a person cannot
/// already click. Arrangement and maintenance remain one step away in the main window.
struct StatusPanel: View {

    @ObservedObject private var revealer = RevealCoordinator.shared

    /// One row in the VISIBLE list.
    ///
    /// `ObservedItem` alone cannot drive a row: it carries no notion of pinned
    /// versus system membership, and that distinction is exactly what the
    /// PINNED and SYSTEM badges exist to show. Rather than guess it from
    /// `bundleID` inside the row view (which would silently misclassify any
    /// bundle not on a hardcoded list), the caller states it once here. Real
    /// pin-membership tracking is a later stage's job; this wrapper is the seam
    /// that stage will fill in, not a permanent guess.
    struct VisibleRow: Identifiable, Sendable {
        let item: ObservedItem
        /// True ONLY for a row whose resolved `owner.bundleID` starts with
        /// `com.apple.`. Never a guess: the window server itself cannot answer
        /// this, since every status item, third-party included, reports the
        /// Control Center process as `kCGWindowOwnerPID`. `owner` resolves
        /// through `BarItemOwners`, which asks the REAL owning application, so
        /// this reads that owner's own bundle id rather than Control Center's.
        let isSystem: Bool
        /// The item's real owning application, or nil when no running
        /// application claims this item's position. Carried on the row
        /// (rather than the row re-resolving from a claims list on every
        /// render) so `displayName` and `icon` below are cheap properties.
        let owner: BarItemOwners.Owner?

        var id: CGWindowID { item.id }

        /// What the row actually shows: the resolved owner's name, or an
        /// explicit statement that the owner is unknown.
        ///
        /// `ObservedItem.ownerName` is never the answer: it is derived from
        /// `ownerPID`, which is Control Center for every item on this OS, so
        /// rendering it would label the whole bar "Control Center". `owner`
        /// resolves through `BarItemOwners` instead, which asks each running
        /// application for its own `AXExtrasMenuBar` and so can genuinely name
        /// a third-party item. Nil stays nil here on purpose: a row this
        /// project could not identify must say so, not restate the wrong name.
        var displayName: String { owner?.name ?? "Unidentified item" }

        /// The row's real app icon, resolved through the owner's real pid, or
        /// nil when no application claims this item.
        ///
        /// `ObservedItem.icon` used to be the source for this and it was the
        /// reported defect: it reads `NSRunningApplication(processIdentifier:
        /// ownerPID)`, and `ownerPID` is Control Center for the whole bar, so
        /// every row drew the same identical icon. `owner.pid` is the item's
        /// REAL owning process, recovered via `BarItemOwners`, so the icon
        /// resolved from it is the item's own app icon.
        @MainActor
        var icon: NSImage? {
            guard let owner else { return nil }
            return NSRunningApplication(processIdentifier: owner.pid)?.icon
        }

        /// Whether `bundleID` is one of Apple's own. Pure string prefix test,
        /// factored out so it is testable without an owner, a claim, or an AX
        /// walk of any kind.
        static func isAppleBundle(_ bundleID: String) -> Bool {
            // Forwards rather than repeating the prefix test. Both spellings were added in the same
            // change, so this was two copies introduced together rather than inherited debt, and
            // `VisibleRowIdentity` is the better home: it already namespaces the sibling predicate
            // `cannotBeAddressedIndividually`, so the two Apple questions sit together where they
            // can be compared. Kept as a name because this pane's callers read better for it, and
            // because it takes a non-optional where the other is optional-tolerant.
            VisibleRowIdentity.isApple(bundleID)
        }

        /// Groups rows so the panel reads as a bar: Apple's own items together,
        /// third-party items together, each group kept in the bar order it
        /// arrived in.
        ///
        /// Before real identity, sorting was purely by x, which interleaved
        /// system and third-party rows in whatever order they happened to sit
        /// physically. With `owner` now resolvable, grouping reads far more
        /// like the bar it is describing: everything the user actually manages
        /// together, everything Stow cannot touch together. Third-party first,
        /// since the VISIBLE list exists for the items a user might tuck or
        /// pin, not for Control Center's own.
        static func grouped(_ rows: [VisibleRow]) -> [VisibleRow] {
            rows.filter { !$0.isSystem } + rows.filter(\.isSystem)
        }
    }

    let state: BarState
    /// The apps Stow is hiding, which is what this panel now offers.
    ///
    /// Replaces `visibleRows`. Those were the items ON the bar, which the user can already
    /// reach by clicking them, and on a crowded bar there were seventeen of them needing no
    /// action at all.
    let hiddenApps: [HiddenApp]
    /// Failures from the latest manual or launch arrangement.
    let arrangementFailures: [BarArranger.Outcome.Failure]

    /// Shows or hides every configured app in one action.
    var onTuckAllButPinned: () -> Void = {}
    /// Which of the three states the bar is in, so the one primary control can state what
    /// pressing it will do rather than what it last did.
    ///
    /// A `Presentation` and not a boolean: the two zones still produce three presentation
    /// states because hidden apps can be revealed temporarily without changing configuration.
    var presentation: HideController.Presentation = .everything
    /// Temporarily reveals one hidden app and opens its menu.
    var onOpenHidden: (HiddenApp) -> Void = { _ in }
    /// Hands off to the updater surface being built concurrently
    /// (`Updater.swift`). Kept as an injected closure rather than a direct
    /// call so this file never needs to know that type's internals, or even
    /// that it compiled yet.
    var onUpdate: () -> Void = {}
    var onArrange: () -> Void = {}
    var onDiagnostics: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    /// Whether an update is actually installable, so the update row can be conditional.
    var updateAvailable = false
    var profiles: [Config.Profile] = []
    var activeProfileID: String?
    var canUndoProfile = false
    var onApplyProfile: (String) -> Void = { _ in }
    var onUndoProfile: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !profiles.isEmpty { profileSwitcher }
            if !arrangementFailures.isEmpty {
                failureBanner
            }
            visibleSection
            actionsSection
        }
        .frame(width: 340)
        .background(auroraCanvas)
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(arrangementFailures.count == 1
                  ? "Stow could not finish the arrangement"
                  : "Stow could not finish \(arrangementFailures.count) changes",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StowTheme.orange)
            ForEach(Array(arrangementFailures.enumerated()), id: \.offset) { _, failure in
                Text(failure.userMessage(displayName: Self.displayName))
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(StowTheme.orange.opacity(0.10))
    }

    private static func displayName(_ bundleID: String) -> String {
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

    // MARK: - Header

    /// Identity, current state, and the management command people use most.
    /// Capacity arithmetic belongs in Diagnostics; it is not actionable in this compact panel.
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: StowGlyph.image(for: state, size: NSSize(width: 22, height: 22),
                                           glow: false))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Stow")
                    .font(.headline)
                    .foregroundStyle(StowTheme.ink)
                Text(hiddenStatus)
                    .font(.caption)
                    .foregroundStyle(StowTheme.inkSoft)
            }
            Spacer()
            Button("Arrange", systemImage: "rectangle.3.group", action: onArrange)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(StowTheme.inkSoft)
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Aurora.raised, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(StowTheme.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var hiddenStatus: String {
        guard !hiddenApps.isEmpty else { return "No apps in Stow" }
        let count = hiddenApps.count
        switch presentation {
        case .tidy: return "\(count) app\(count == 1 ? "" : "s") hidden"
        case .revealed: return "All apps visible temporarily"
        case .everything: return "All apps visible"
        }
    }

    private var profileSwitcher: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(profiles) { profile in
                    Button {
                        onApplyProfile(profile.id)
                    } label: {
                        if profile.id == activeProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
                    Text(profiles.first(where: { $0.id == activeProfileID })?.name
                         ?? "Choose Profile")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(StowTheme.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StowTheme.inkMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Aurora.inset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StowTheme.hairline))
            }
            .menuStyle(.borderlessButton)
            Spacer(minLength: 0)
            if canUndoProfile {
                Button("Undo", systemImage: "arrow.uturn.backward", action: onUndoProfile)
                    .font(.system(size: 10.5, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(StowTheme.inkSoft)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    // MARK: - the sub-bar

    /// The apps Stow is HIDING, as icons you can click.
    ///
    /// This section used to list what was on the bar, which was the wrong set twice over. Those
    /// are the items the user can already reach by clicking them in the bar itself, and on a
    /// crowded bar the list ran to seventeen rows of things needing no action. What they cannot
    /// reach is what Stow hid, so that is what this shows.
    ///
    /// Only possible because a pushed item can still be opened: verified on a real hidden app
    /// at x-3036, whose menu opened when pressed. So this offers the hidden run without
    /// revealing it.
    private var visibleSection: some View {
        SubBar(apps: hiddenApps, state: state,
               revealPresentation: revealer.presentation,
               actionTitle: shelfActionTitle, actionSymbol: shelfActionSymbol,
               onOpen: onOpenHidden,
               onToggle: hiddenApps.isEmpty ? onArrange : onTuckAllButPinned)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updateAvailable {
                QuietRow(title: "Update now", symbol: "arrow.down.circle", action: onUpdate)
            }
            PanelFooter(diagnostics: onDiagnostics, settings: onSettings, quit: onQuit)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// What the pill offers, given the state the bar is in.
    ///
    /// From `tidy` the useful move is a reveal, which is the everyday gesture. From anywhere
    /// else it is to tidy up again. `everything` reads as "Hide" rather than "Tidy" because a
    /// user who has hidden nothing yet has no mental model of tidy to appeal to.
    private var shelfActionTitle: String {
        if hiddenApps.isEmpty { return "Add Apps" }
        switch presentation {
        case .tidy: return "Show All"
        case .revealed: return "Hide Again"
        case .everything: return "Hide \(hiddenApps.count)"
        }
    }

    private var shelfActionSymbol: String {
        if hiddenApps.isEmpty { return "plus" }
        return presentation == .tidy ? "eye" : "eye.slash"
    }

    /// A continuous, quiet canvas. Aurora lives in the top edge and a low-opacity wash rather
    /// than a fixed-height glow that ends abruptly in the app grid.
    private var auroraCanvas: some View {
        let stops = StowTheme.stops(for: state)
        return ZStack(alignment: .top) {
            StowTheme.canvas
            LinearGradient(colors: [stops.first?.opacity(0.08) ?? .clear,
                                    (stops.last ?? .clear).opacity(0.035),
                                    .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .allowsHitTesting(false)
            Rectangle()
                .fill(StowTheme.sweep(for: state))
                .frame(height: 2)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Action rows

/// A quiet action row: icon, label, done. Everything the panel offers that is
/// not the one pill lands here rather than as a second bright button, which is
/// what keeps "primary" meaning something.
private struct QuietRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(StowTheme.inkSoft)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StowTheme.ink)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Color.white.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Common navigation stays visible and labelled. Refresh already occurs whenever the panel
/// opens, and release notes remain in the main window, so neither needs permanent panel chrome.
private struct PanelFooter: View {
    let diagnostics: () -> Void
    let settings: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Settings", systemImage: "gearshape", action: settings)
                .labelStyle(.titleAndIcon)
                .buttonStyle(.plain)
                .foregroundStyle(StowTheme.inkSoft)
            Button("Doctor", systemImage: "stethoscope", action: diagnostics)
                .labelStyle(.titleAndIcon)
                .buttonStyle(.plain)
                .foregroundStyle(StowTheme.inkSoft)
            Spacer()
            Text(StowVersion.display)
                .font(.caption)
                .foregroundStyle(StowTheme.inkMuted)
                .help(StowVersion.builderAttribution)
            Button("Quit Stow", systemImage: "power", action: quit)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(StowTheme.inkSoft)
                .help("Quit Stow")
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }
}

// MARK: - Sample data

extension StatusPanel {
    /// Synthetic sample data, no live wiring required.
    ///
    /// The numbers echo `docs/design-v3.html` section 8 (1512pt display, 214pt
    /// of app menus, 268pt of system trailing items, a 74pt and a 30pt pinned
    /// item) so this factory and the design mock can be checked against each
    /// other directly. Real `BarScanner` and `PressActionProbe` wiring is a
    /// later stage; this factory exists so the surface is inspectable now.
    ///
    /// Deliberately a factory rather than a `#Preview` block. The macro needs
    /// Xcode's `PreviewsMacros` plugin, which a Command Line Tools only
    /// toolchain does not ship, so a `#Preview` here fails the release build
    /// outright. AuthBar and Murmur use none for the same reason. Do not add one.
    static func sample(state: BarState = .crowded) -> StatusPanel {
        // Hidden apps rather than bar rows, matching what the panel now shows. Icons are nil
        // for the same reason the old sample used no images: resolving a real one would make
        // this factory depend on what happens to be installed.
        return StatusPanel(
            state: state,
            hiddenApps: [
                HiddenApp(bundleID: "com.starkpat.AuthBar", name: "AuthBar",
                          icon: nil, zone: .tucked, pid: 2),
                HiddenApp(bundleID: "com.starkpat.Murmur", name: "Murmur",
                          icon: nil, zone: .tucked, pid: 3),
                HiddenApp(bundleID: "com.example.utility", name: "Utility",
                          icon: nil, zone: .tucked, pid: 4),
            ],
            arrangementFailures: [])
    }
}

extension StatusPanel {

    /// `Stow --panel`: measures real layouts and writes a six-app PNG preview.
    ///
    /// A `MenuBarExtra` popover dismisses when focus changes, so offscreen rendering keeps
    /// geometry and visual review deterministic without disturbing the live menu session.
    ///
    /// `ImageRenderer` lays the real view out offscreen, so this is the shipped view's own
    /// geometry rather than a mock's.
    @MainActor
    static func runPanelAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - panel")
        print(String(repeating: "=", count: 68))

        func measure(_ label: String, _ view: some View) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage else {
                print("  \(label): could not be laid out")
                return
            }
            print("  \(label): \(Int(image.size.width)) x \(Int(image.size.height))pt")
        }

        func previewApp(_ bundleID: String, zone: Zone) -> HiddenApp? {
            let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first
            let installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            guard running != nil || installedURL != nil else { return nil }
            let name = running?.localizedName
                ?? installedURL?.deletingPathExtension().lastPathComponent
                ?? bundleID
            let icon = running?.icon ?? installedURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return HiddenApp(bundleID: bundleID, name: name, icon: icon,
                             zone: zone, pid: running?.processIdentifier ?? 0)
        }

        let configuredApps = (Config.load().zoneByBundleID ?? [:])
            .filter { $0.value != .pinned }
            .compactMap { previewApp($0.key, zone: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let fallbackApps = ["Calendar", "Mail", "Notes", "Reminders", "Tasks", "Weather"]
            .enumerated()
            .map { index, name in
                HiddenApp(bundleID: "com.example.preview.\(index)", name: name,
                          icon: nil, zone: .tucked, pid: 0)
            }
        let sixAppPanel = StatusPanel(
            state: .tidy,
            hiddenApps: configuredApps.isEmpty ? fallbackApps : Array(configuredApps.prefix(6)),
            arrangementFailures: [],
            presentation: .tidy)

        // Three real configurations, because the panel's height is dominated by how much is
        // hidden and whether an update is pending, not by its chrome alone.
        measure("nothing hidden            ",
                StatusPanel(state: .tidy,
                            hiddenApps: [],
                            arrangementFailures: []))
        measure("one app tucked            ",
                StatusPanel(state: .tidy,
                            hiddenApps: [
                                HiddenApp(bundleID: "com.microsoft.Outlook", name: "Outlook",
                                          icon: nil, zone: .tucked, pid: 1),
                            ],
                            arrangementFailures: []))
        measure("three apps hidden         ", sample())
        measure("six apps hidden           ", sixAppPanel)
        measure("three hidden + update     ", {
            var panel = sample()
            panel.updateAvailable = true
            return panel
        }())

        let previewRenderer = ImageRenderer(content: sixAppPanel)
        previewRenderer.scale = 2
        if let image = previewRenderer.nsImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: "/tmp/stow-panel-preview.png")
            try? png.write(to: url, options: .atomic)
            print("  preview                     : \(url.path)")
        }

        print("")
        print("  BEFORE, measured the same way at fee8cbc, for comparison:")
        print("    nothing hidden             : 340 x 338pt")
        print("    one app tucked             : 340 x 378pt")
        print("    three apps hidden          : 340 x 458pt")
        print("")
        print("  The old panel spent that height on a five-line budget card, two permanent")
        print("  update rows and a version footer, all ahead of the hidden run, which is the")
        print("  one thing the panel is opened to reach.")
        exit(0)
    }
}
