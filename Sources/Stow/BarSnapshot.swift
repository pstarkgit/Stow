import AppKit
import CoreGraphics
import SwiftUI

/// Produces the live inputs `StatusPanel` renders: what is in the bar right now,
/// how much room is left, and which state that implies.
///
/// Deliberately thin. It owns no policy and persists nothing, because zone
/// membership (`pinned`, `tucked`) is a stored user decision and the
/// subsystem that stores it does not exist yet. What it does own is the one job
/// that IS answerable today: ask `BarScanner` what is on the bar, ask
/// `MenuWidthProbe` for the two widths `BarBudget` used to receive as zero, and
/// hand the arithmetic to `BarBudget` rather than doing any of it here.
///
/// The panel therefore shows measured truth rather than sample data, and the
/// fields that genuinely cannot be known yet report as unknown rather than as
/// plausible-looking zeros.
@MainActor
final class BarSnapshot: ObservableObject {

    /// Items currently in the bar, grouped Apple's own first then third-party,
    /// each group in bar order (rightmost first). See
    /// `StatusPanel.VisibleRow.grouped(_:)` for why the grouping exists.
    @Published private(set) var rows: [StatusPanel.VisibleRow] = []
    /// Every claim resolved this refresh, kept so a caller that needs to
    /// re-derive something about the bar (the Doctor, a future stage) never
    /// has to re-walk `BarItemOwners.claims()` itself.
    @Published private(set) var owners: [BarItemOwners.Owner] = []
    /// The budget for the display carrying the menu bar.
    @Published private(set) var budget = BarBudget(
        screenWidth: 0, appMenuWidth: 0, notchWidth: 0,
        systemTrailingWidth: 0, occupiedWidths: [])
    /// The state the budget implies, which is what the bar glyph wears.
    @Published private(set) var state: BarState = .tidy
    /// Name of the display being reported on.
    @Published private(set) var displayName = ""

    /// Stow's OWN seam window numbers, so they can be excluded from occupancy.
    ///
    /// Set by the caller that owns the `HideController`, because identity is the whole
    /// problem here: every status item on macOS 26 reports Control Center as its owner, so
    /// a bundle-identifier test can never recognise Stow's own seam. Window number is the
    /// only thing that can, which is why `MainWindow` has always excluded on it.
    var seamWindows: Set<CGWindowID> = []

    private let widths = MenuWidthProbe()

    /// The in-flight owner walk, so a rapid series of panel opens cancels the
    /// previous walk rather than queuing several 0.96s walks behind each other.
    ///
    /// A `Task` and not a token: `deinit` on a `@MainActor` class is nonisolated and
    /// may only touch Sendable stored properties, and `Task` is one. The same
    /// constraint already bit `MenuWidthProbe`, whose notification observer could not
    /// be released from `deinit` for exactly this reason.
    private var ownerWalk: Task<Void, Never>?

    init() {
        refresh()
    }

    deinit {
        ownerWalk?.cancel()
    }

    /// Re-measures the bar and publishes twice: immediately from what is already
    /// known, then again once the expensive walk finishes.
    ///
    /// The two-stage shape exists because one stage is 96 percent of the cost.
    /// Measured: the window-server passes take 0.039s, the frontmost-app menu walk
    /// 0.001s, Control Center's own extras 0.011s, and
    /// `BarItemOwners.claims()` 0.965s. Running all of it synchronously on a panel
    /// open made the panel hang for about a second before drawing anything, which is
    /// what it did in the first version of this file.
    ///
    /// So the cheap measurements run inline and the panel draws at once, using the
    /// last known owners for names. Those names are almost always still correct, since
    /// the set of applications owning status items changes only when one launches or
    /// quits. The walk then runs in a `Task` and publishes corrected rows a beat
    /// later. A first-ever open has no cache, so it briefly shows unnamed rows and
    /// then fills them in, which is a visible improvement on showing nothing at all
    /// for a second.
    func refresh() {
        applyCheapMeasurements(using: BarItemOwners.lastKnownClaims)

        // Cancel any walk still in flight, so rapid opens do not queue several.
        ownerWalk?.cancel()
        ownerWalk = Task { @MainActor [weak self] in
            let fresh = BarItemOwners.cachedClaims()
            guard !Task.isCancelled, let self else { return }
            self.applyCheapMeasurements(using: fresh)
        }
    }

    /// Everything except the owner walk, plus row construction against whichever
    /// claims the caller supplies.
    private func applyCheapMeasurements(using claims: [BarItemOwners.Owner]) {
        guard let screen = NSScreen.main else { return }

        widths.recompute()
        let barRect = BarScanner.menuBarRect(for: screen)
        let scan = BarScanner.scan(menuBarRect: barRect)
        let onBar = BarBudget.ordinaryItems(in: scan.items,
                                            screenWidth: screen.frame.width,
                                            excluding: seamWindows)

        // Resolve every item against ONE claims list, passed in rather than walked
        // here: the identity question was previously asked of the wrong process, and
        // the fix is not to now ask the right one once per row.
        //
        // Apple's own extras are claimed too, by Control Center itself, so `isSystem`
        // reads the resolved owner's OWN bundle id. A third-party app's bundle id is
        // its own, never Control Center's, so the `com.apple.` prefix test cannot
        // mistake one for the other the way matching on position alone could.
        owners = claims
        let resolved = onBar.map { item -> StatusPanel.VisibleRow in
            let owner = item.owner(in: claims)
            let isSystem = owner.map { StatusPanel.VisibleRow.isAppleBundle($0.bundleID) } ?? false
            return StatusPanel.VisibleRow(item: item, isSystem: isSystem, owner: owner)
        }
        rows = StatusPanel.VisibleRow.grouped(resolved)

        // A nil measurement means "not measurable," so it must not be laundered into
        // a confident zero. Passing zero is what makes `usable` an upper bound rather
        // than a claim, and `Probe` section 5 prints that caveat for exactly the
        // fields that came back nil.
        //
        // Stow's OWN items are excluded from occupancy. While hiding, a seam is about
        // 5,000pt wide, and counting that as consumed bar space made this panel report
        // "-3,889 pt headroom of 2,240 usable" on screen. A seam is not an item
        // competing for room; it IS the mechanism that makes room. The Arrange pane was
        // fixed for this and the panel was not, which is how the same wrong number
        // survived in one surface after being corrected in the other.
        //
        // Prefer exact WINDOW NUMBER exclusion. The width ceiling is the fallback
        // for standalone diagnostics such as `--rows`, which run in a second
        // process and therefore cannot receive the live app's private seam id.
        // A 5,016pt boundary on a 1,728pt display is a mechanism, never an
        // ordinary item competing for room.
        budget = BarBudget(
            screenWidth: screen.frame.width,
            appMenuWidth: widths.frontmostAppMenuWidth ?? 0,
            notchWidth: BarScanner.notchWidth(for: screen),
            systemTrailingWidth: widths.systemTrailingWidth ?? 0,
            occupiedWidths: BarBudget.occupiedWidths(in: onBar,
                                                      screenWidth: screen.frame.width,
                                                      excluding: seamWindows))

        // Nothing is tucked yet, so crowding can only come from the bar already
        // overflowing. `BarBudget.state(widestTucked:)` handles that case itself when
        // passed nil, which is why no widest-item guess is invented here.
        state = budget.state(widestTucked: nil)
        displayName = screen.localizedName
    }

    /// Blocks until owners are resolved. For `--rows` and any other diagnostic that
    /// must report a complete picture rather than a progressive one.
    func refreshSynchronously() {
        applyCheapMeasurements(using: BarItemOwners.refreshCache())
    }
}

extension BarSnapshot {

    /// `Stow --rows`: prints exactly what the panel's VISIBLE list would render, and
    /// how long producing it took.
    ///
    /// This mode exists because of a specific gap. The naming fix was verified
    /// through `Probe` phase 4, which resolves owners the same way, but the PANEL's
    /// own path, `BarSnapshot.refresh()` feeding `StatusPanel.VisibleRow`, had no
    /// verification at all: a `MenuBarExtra` popover dismisses on any focus change,
    /// every screen-capture mechanism available takes focus, and
    /// `CGWindowListCreateImage` is obsoleted in macOS 15, so the rendered rows could
    /// not be observed. Printing the rows through the real code path is the check
    /// that was missing, and unlike a screenshot it can be re-run and diffed.
    ///
    /// It also times the refresh, because the first version of that refresh took most
    /// of ten seconds to open the panel.
    static func runRowsAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - rows")
        print(String(repeating: "=", count: 68))
        print("  accessibility granted : \(PressActionProbe.isTrusted ? "YES" : "NO")")
        if !PressActionProbe.isTrusted {
            print("  ! Without it no application can be asked what it owns, so every row")
            print("    below will read Unidentified item. Grant it in System Settings.")
        }

        // Time the two stages separately, because the whole point of the split is
        // that the panel does not wait for the second one. The first figure is what
        // the user actually feels on a click.
        let startedFast = Date()
        let snapshot = BarSnapshot()
        let fast = Date().timeIntervalSince(startedFast)

        let startedFull = Date()
        snapshot.refreshSynchronously()
        let full = Date().timeIntervalSince(startedFull)

        print("")
        print(String(format: "  first paint (felt)    : %.3fs", fast))
        print(String(format: "  full owner walk       : %.3fs", full))
        print("  applications claiming : \(snapshot.owners.count)")
        print("  rows the panel shows  : \(snapshot.rows.count)")
        print("  display               : \(snapshot.displayName)")
        print("  bar state             : \(snapshot.state)")
        print("")
        print("  " + pad("NAME", 30) + pad("BADGE", 9) + pad("WIDTH", 7) + "BUNDLE")
        for row in snapshot.rows {
            let badge = row.isSystem ? "SYSTEM" : (row.owner == nil ? "UNKNOWN" : "APP")
            print("  " + pad(row.displayName, 30) + pad(badge, 9)
                  + pad("\(Int(row.item.frame.width))pt", 7)
                  + (row.owner?.bundleID ?? ""))
        }
        print("")
        let named = snapshot.rows.filter { $0.owner != nil }.count
        print("  \(named) of \(snapshot.rows.count) rows resolved to a real application.")
        print("  \(snapshot.budget.arithmetic)")
        exit(0)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
}

extension BarSnapshot {

    /// `Stow --open <name>`: resolves a bar item by owner name and opens its menu
    /// through the SAME call the panel row makes.
    ///
    /// This exists because the panel's click cannot be driven from a test. Synthetic
    /// mouse events are ignored for menu bar interaction on this OS (measured: a
    /// synthesised command-drag left a status item exactly where it started), so
    /// there is no way to verify the row's action by pretending to be a user. A CLI
    /// entry point that calls `PressActionProbe.press` with an owner resolved by
    /// `BarItemOwners` exercises every part of the row's path except the click
    /// itself, and unlike a screenshot it re-runs and diffs.
    static func runOpenAndExit(matching needle: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - open")
        print(String(repeating: "=", count: 68))

        guard PressActionProbe.isTrusted else {
            print("  accessibility  : NO")
            print("  Without it no item can be identified or pressed. Grant it first.")
            exit(2)
        }

        let claims = BarItemOwners.refreshCache()
        let wanted = needle.lowercased()
        guard let owner = claims.first(where: { $0.name.lowercased().contains(wanted) }) else {
            print("  no bar item is owned by an app matching \"\(needle)\"")
            print("  known owners: " + claims.map(\.name).sorted().joined(separator: ", "))
            exit(1)
        }

        print("  target         : \(owner.name) (pid \(owner.pid))")
        print("  bundle         : \(owner.bundleID)")

        let started = Date()
        let opened = PressActionProbe.press(pid: owner.pid)
        let elapsed = Date().timeIntervalSince(started)

        print(String(format: "  press took     : %.3fs", elapsed))
        print("  menu opened    : \(opened ? "YES" : "NO")")
        if opened {
            print("")
            print("  \(owner.name)'s menu is open. Stow did not move the spacer, did not")
            print("  wait for a relayout, and did not need any item to be off the bar.")
        }
        exit(opened ? 0 : 1)
    }
}
