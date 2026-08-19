import SwiftUI
import AppKit

/// Stow's 340pt dropdown, the MANAGEMENT surface.
///
/// This is explicitly not the everyday interaction. Design v3 section 8 made
/// that demotion in words: "The sub-bar owns the everyday interaction, so the
/// panel's old multi-zone row lists are redundant and have been
/// removed. What remains is what the sub-bar cannot do: state your capacity
/// honestly, offer the update, and open the window. VISIBLE stays, because
/// pinned membership is a management decision rather than a click target."
///
/// The consequence for this file is concrete: there is no hidden-state table
/// anywhere below, only their counts in the header. Adding one back would be
/// exactly the regression section 8 exists to prevent, since the sub-bar
/// (`SubBarPanel`, a later stage) is where a user actually reveals or re-shelves
/// an item day to day.
struct StatusPanel: View {

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
    let budget: BarBudget
    /// The apps Stow is hiding, which is what this panel now offers.
    ///
    /// Replaces `visibleRows`. Those were the items ON the bar, which the user can already
    /// reach by clicking them, and on a crowded bar there were seventeen of them needing no
    /// action at all.
    let hiddenApps: [HiddenApp]
    /// The display this budget was measured against, "Studio Display",
    /// "Built-in Retina Display". Shown beside the headroom figure so a
    /// multi-monitor user is never left guessing which screen the number
    /// describes.
    let displayName: String

    /// Tucks every non-pinned item in one action. The one primary action this
    /// panel offers, and per the design brief the panel's ONLY filled Aurora
    /// pill: "primary only means something if it is rare."
    var onTuckAllButPinned: () -> Void = {}
    /// Which of the three states the bar is in, so the one primary control can state what
    /// pressing it will do rather than what it last did.
    ///
    /// A `Presentation` and not a boolean: three zones produce three states, and the middle
    /// one, with hidden apps returned temporarily, is the one the design exists for.
    var presentation: HideController.Presentation = .everything
    /// Opens one visible item's own menu, the panel's cheapest and most useful
    /// action.
    ///
    /// This is deliberately NOT a reveal. An item that answers `kAXPressAction` can
    /// be opened where it stands, with no spacer movement, no relayout wait and no
    /// timing window, which measured at 15 of 15 items on the bar this was written
    /// against. So the everyday "let me get at that icon" case never touches the
    /// risky machinery at all, and works before any spacer has been positioned.
    var onOpenHidden: (HiddenApp) -> Void = { _ in }
    /// Hands off to the updater surface being built concurrently
    /// (`Updater.swift`). Kept as an injected closure rather than a direct
    /// call so this file never needs to know that type's internals, or even
    /// that it compiled yet.
    var onUpdate: () -> Void = {}
    /// Hands off to `WhatsNewPane`, same reasoning as `onUpdate`.
    var onReadNotes: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onDiagnostics: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    /// Whether an update is actually installable, so the update row can be conditional.
    var updateAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The hidden run gets TOP BILLING, directly under the header.
            //
            // It is the reason the panel is opened: these are the only apps the user cannot
            // reach by clicking the bar itself. It used to sit third, below a five-line budget
            // card, so a panel opened to reach one hidden app answered a question about
            // arithmetic first. Reported as "why so much, and it's huge": one hidden app cost
            // an 826pt popover.
            visibleSection
            hairline(fullWidth: true)
            actionsSection
        }
        // 340pt, unchanged from AuthBar's own panel: wide enough for the
        // arithmetic line to read as one line rather than wrapping, narrow
        // enough that the dropdown still reads as a dropdown and not a window.
        .frame(width: 340)
        .background(auroraCanvas)
    }

    // MARK: - Header

    /// Title, state counts, and the ONE budget fact worth showing here.
    ///
    /// The budget used to be a bordered five-line card: a kicker, a 19pt figure, a gauge, and
    /// the full arithmetic string wrapped over two lines. That is a developer's view of the
    /// bar, and it was the first thing the panel said. The arithmetic still exists in full
    /// under Diagnostics, which is where a number nobody acts on belongs; what a user acts on
    /// is whether there is room, so that is what survives here as one line.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Small, unglowed. The glow reads fine at 18pt in the menu bar
                // itself; inside a 340pt panel next to body text it would bloom
                // past the token's own corner radius and smudge into the title.
                Image(nsImage: StowGlyph.image(for: state, size: NSSize(width: 17, height: 17),
                                               glow: false))
                Text("Stow")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(StowTheme.ink)
                Spacer()
                Text("\(hiddenApps.count) in Stow")
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
            }
            HStack(spacing: 6) {
                Text(headroomFigure)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(budget.headroom < 0 ? StowTheme.rose : StowTheme.inkSoft)
                Text("free on")
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
                Text(displayName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// "38pt", or a negative figure when macOS is already clipping. Negative
    /// headroom is a real state `BarBudget` reports honestly, so this string
    /// reports it honestly too rather than clamping it to zero and hiding the
    /// problem from the one surface built to explain it.
    private var headroomFigure: String {
        "\(Int(budget.headroom.rounded()))pt"
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
        SubBar(apps: hiddenApps, state: state, onOpen: onOpenHidden)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            // One control, three labels, because the pill must say what pressing it will DO
            // and there are now three states. A button reading "Hide" while things are
            // already hidden leaves the user guessing whether the last press worked, and the
            // whole point of this control is that its effect is invisible by design.
            //
            // Deliberately not a three-way cycle. `everything` is a configuration outcome,
            // reached by setting every app to Shown, not a state to land in by pressing a
            // button twice, and a cycle would make one press in three appear to do nothing.
            AuroraPill(title: pillTitle, symbol: pillSymbol,
                       state: state, action: onTuckAllButPinned)
            // ONLY when there is something to install.
            //
            // These were two permanent rows offering an update that usually does not exist and
            // release notes for a version already running. On a panel whose whole job is to
            // reach a hidden app, that is two rows of chrome ahead of the one thing being
            // looked for. Both are still reachable: notes moved into the icon row, and this
            // row appears the moment a real update does.
            if updateAvailable {
                QuietRow(title: "Update now", symbol: "arrow.down.circle", action: onUpdate)
            }
            IconActionRow(refresh: onRefresh, diagnostics: onDiagnostics,
                          settings: onSettings, notes: onReadNotes, quit: onQuit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// What the pill offers, given the state the bar is in.
    ///
    /// From `tidy` the useful move is a reveal, which is the everyday gesture. From anywhere
    /// else it is to tidy up again. `everything` reads as "Hide" rather than "Tidy" because a
    /// user who has hidden nothing yet has no mental model of tidy to appeal to.
    private var pillTitle: String {
        switch presentation {
        case .tidy: return "Open Stow"
        case .revealed: return "Close Stow"
        case .everything: return "Move extras into Stow"
        }
    }

    private var pillSymbol: String {
        presentation == .tidy ? "chevron.up" : "chevron.down"
    }

    // MARK: - Shared bits

    /// A hairline divider. `fullWidth` matches the mock's `.hr` versus
    /// `.hr.full`: the budget-to-rows seam sits inset with the rest of the
    /// panel's content, while the rows-to-actions seam runs edge to edge as
    /// the panel's one full-bleed structural line.
    private func hairline(fullWidth: Bool) -> some View {
        Rectangle()
            .fill(StowTheme.hairline)
            .frame(height: 1)
            .padding(.horizontal, fullWidth ? 0 : 10)
    }

    /// The aurora edge: two offset radial glows in the state's own gradient,
    /// leaking from the panel's top rim. Two glows at 30 percent and 75
    /// percent read as an aurora; one centred glow would read as a spotlight.
    /// Ported from AuthBar's `auroraCanvas`, with the state driving the stops
    /// so the panel agrees with whichever token the menu bar is showing right
    /// now.
    private var auroraCanvas: some View {
        let stops = StowTheme.stops(for: state)
        return ZStack(alignment: .top) {
            StowTheme.canvas
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .top) {
                    RadialGradient(colors: [stops.first?.opacity(0.16) ?? .clear, .clear],
                                  center: .init(x: 0.30, y: 0), startRadius: 0, endRadius: w * 0.70)
                    RadialGradient(colors: [(stops.last ?? .clear).opacity(0.13), .clear],
                                  center: .init(x: 0.75, y: 0), startRadius: 0, endRadius: w * 0.70)
                }
                .frame(height: 120)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - the sub-bar's tiles

/// One item in the sub-bar: its icon, and a click that opens its menu.
///
/// Replaces `VisibleItemRow`, a full-width row carrying icon, name, width and badge. That
/// row was a table cell, and this panel is not a table: the everyday act is clicking the
/// icon you were reaching for, so the icon is the control and everything else is a tooltip.
///
/// A system item is drawn dimmed and is NOT clickable, because Stow cannot press Apple's own
/// extras. Offering a click target there would be an action that silently does nothing.
private struct SubBarTile: View {
    let row: StatusPanel.VisibleRow
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering && isOpenable ? StowTheme.cardHover : Aurora.raised)
                if let icon = row.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .opacity(row.isSystem ? 0.5 : 1)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 13))
                        .foregroundStyle(StowTheme.inkMuted)
                }
            }
            .frame(width: 34, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(hovering && isOpenable ? StowTheme.hairline : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isOpenable)
        .onHover { hovering = $0 }
        // The name lives HERE rather than beside the icon. A 34pt tile cannot carry
        // "Microsoft Outlook" legibly, and the icon is the recognisable thing anyway; the
        // tooltip is what covers the one case it is not, an unidentified item.
        .help(helpText)
        .accessibilityLabel(row.displayName)
        .accessibilityHint(isOpenable ? "Opens this item's menu" : "Stow cannot open this")
    }

    /// Whether clicking can actually do something: Stow must know which process owns the item
    /// in order to press it, and must not offer to press Apple's own extras.
    private var isOpenable: Bool { !row.isSystem && row.owner != nil }

    private var helpText: String {
        let width = "\(Int(row.item.frame.width.rounded()))pt"
        if row.isSystem { return "\(row.displayName) · system · \(width)" }
        if row.owner == nil { return "Unidentified item · \(width)" }
        return "\(row.displayName) · \(width) · click to open"
    }
}

/// Row leading icon: a 22pt chip wearing a gradient mark on a tinted tile.
///
/// Ported from AuthBar's `TypeIcon`, one deliberate change: `VisibleRow`
/// carries the item's real app icon (`icon`, resolved through the real owning
/// process recovered by `BarItemOwners`, never the window server's
/// Control-Center-for-everyone `ownerPID`), which is exactly the
/// recognisability AuthBar's SF Symbol chip was standing in for. When that
/// icon resolves, showing it is more honest than a generic glyph; the chip's
/// tinted tile is what keeps the row's Stow identity even though the mark
/// inside it is now the app's own art rather than a gradient-filled symbol.
/// The gradient-filled fallback only appears for a row with no resolved
/// owner, or an owner whose process has since exited.
private struct TypeIconChip: View {
    let row: StatusPanel.VisibleRow

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: row.isSystem ? "gearshape.fill" : "app.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StowTheme.diagonal(for: .tidy))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    /// Mirrors `VisibleItemRow.badgeTint`: SYSTEM wears the violet
    /// `AuroraBadge.ssh`, a matched third-party owner wears the cyan
    /// `AuroraBadge.local`, and a genuinely unmatched row wears the neutral
    /// ink rather than borrowing either badge colour it has not earned.
    private var tint: Color {
        if row.isSystem { return AuroraBadge.ssh }
        return row.owner != nil ? AuroraBadge.local : StowTheme.inkMuted
    }
}

// MARK: - Section furniture

/// A small tracked-caps label separating the panel's sections, with an
/// optional attention count.
///
/// Ported unchanged in shape from AuthBar's own `SectionKicker`: the hairline
/// rule after the label reads as structure without spending a whole row on a
/// divider, and the count badge only appears when `badge` is positive, so a
/// freshly launched Stow with nothing needing attention never shows a stray
/// "0" badge next to a section that has nothing to report.
struct SectionKicker: View {
    let title: String
    let state: BarState
    var badge: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StowTheme.inkMuted)
                .kerning(0.8)
            Rectangle()
                .fill(StowTheme.hairline)
                .frame(height: 1)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Aurora.onGradient)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(StowTheme.sweep(for: state), in: Capsule())
                    .accessibilityLabel("\(badge) needing attention")
            }
        }
        .padding(.horizontal, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Action rows

/// The panel's one filled Aurora pill.
///
/// Design v3 section 8 is explicit that primary prominence must stay rare to
/// mean anything, and this file only ever constructs one of these, for "Tuck
/// all but pinned". Every other action below is a quiet row or a link, on
/// purpose: a second filled pill would split the eye and neither action would
/// read as the one the panel exists to offer.
private struct AuroraPill: View {
    let title: String
    let symbol: String
    let state: BarState
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
            }
            // Dark ink on a bright gradient, legible across every state's
            // sweep, the same fixed ink AuroraToggleStyle's ON knob uses.
            .foregroundStyle(Aurora.onGradient)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(StowTheme.sweep(for: state), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(hovering ? 0.28 : 0.14), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

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

/// The panel's four window and lifecycle actions as one compact icon row.
///
/// AuthBar draws its own set of bespoke icons for this row (`AuroraIcons.swift`)
/// so the footer belongs to the same family as the menu bar token. That file
/// does not exist in Stow yet, and porting a hand-drawn icon set is its own
/// piece of work, not something this stage should absorb as a side effect of
/// building the panel around it. SF Symbols stand in here so the row is fully
/// functional today; a later stage can swap the glyphs for drawn art without
/// touching this row's layout or wiring.
private struct IconActionRow: View {
    let refresh: () -> Void
    let diagnostics: () -> Void
    let settings: () -> Void
    let notes: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconGlyphButton(symbol: "arrow.clockwise", label: "Check again", action: refresh)
            IconGlyphButton(symbol: "wrench.and.screwdriver", label: "Diagnostics", action: diagnostics)
            IconGlyphButton(symbol: "gearshape", label: "Settings", action: settings)
            // Release notes live here now rather than on their own row. Same reachability, no
            // permanent row spent on a version already running.
            IconGlyphButton(symbol: "sparkles", label: "Read what's new", action: notes)
            Spacer()
            // The version, which used to be a footer of its own. It is a label, not an action,
            // so it sits in this row's spare width instead of costing a row plus its padding.
            Text(StowVersion.display)
                .font(.system(size: 9))
                .foregroundStyle(StowTheme.inkMuted)
                .help(StowVersion.builderAttribution)
            // Quit is the row's one irreversible action, so it alone hovers
            // rose rather than the row's usual hover tint.
            IconGlyphButton(symbol: "power", label: "Quit Stow", destructive: true, action: quit)
        }
        .padding(.horizontal, 4)
    }
}

/// One footer utility button: quiet chrome at rest, aurora on hover.
private struct IconGlyphButton: View {
    let symbol: String
    let label: String
    var destructive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    private var tint: Color {
        guard hovering else { return StowTheme.inkSoft }
        return destructive ? StowTheme.rose : StowTheme.blue
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 26)
                .background(hovering ? Color.white.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
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
        let budget = BarBudget(screenWidth: 1512, appMenuWidth: 214, notchWidth: 0,
                               systemTrailingWidth: 268, occupiedWidths: [60, 74, 30])
        // Hidden apps rather than bar rows, matching what the panel now shows. Icons are nil
        // for the same reason the old sample used no images: resolving a real one would make
        // this factory depend on what happens to be installed.
        return StatusPanel(
            state: state,
            budget: budget,
            hiddenApps: [
                HiddenApp(bundleID: "com.starkpat.AuthBar", name: "AuthBar",
                          icon: nil, zone: .tucked, pid: 2),
                HiddenApp(bundleID: "com.starkpat.Murmur", name: "Murmur",
                          icon: nil, zone: .tucked, pid: 3),
                HiddenApp(bundleID: "com.example.utility", name: "Utility",
                          icon: nil, zone: .tucked, pid: 4),
            ],
            displayName: "Studio Display")
    }
}

extension StatusPanel {

    /// `Stow --panel`: measures the panel's real laid-out size, and prints its section heights.
    ///
    /// Exists because this surface cannot be screenshotted. A `MenuBarExtra` popover dismisses
    /// on any focus change, every capture mechanism takes focus, and `CGWindowListCreateImage`
    /// is obsoleted on macOS 15, which is the same gap `--rows` was built to close for the row
    /// list. So a claim about the panel getting shorter was previously unverifiable, and "it's
    /// huge" was reported against a panel nobody could measure.
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

        // Three real configurations, because the panel's height is dominated by how much is
        // hidden and whether an update is pending, not by its chrome alone.
        measure("nothing hidden            ",
                StatusPanel(state: .tidy,
                            budget: BarBudget(screenWidth: 2560, appMenuWidth: 289,
                                              notchWidth: 0, systemTrailingWidth: 360,
                                              occupiedWidths: [60, 74, 30]),
                            hiddenApps: [],
                            displayName: "LG ULTRAGEAR+"))
        measure("one app tucked            ",
                StatusPanel(state: .tidy,
                            budget: BarBudget(screenWidth: 2560, appMenuWidth: 289,
                                              notchWidth: 0, systemTrailingWidth: 360,
                                              occupiedWidths: [60, 74, 30]),
                            hiddenApps: [
                                HiddenApp(bundleID: "com.microsoft.Outlook", name: "Outlook",
                                          icon: nil, zone: .tucked, pid: 1),
                            ],
                            displayName: "LG ULTRAGEAR+"))
        measure("three apps hidden         ", sample())
        measure("three hidden + update     ", {
            var panel = sample()
            panel.updateAvailable = true
            return panel
        }())

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
