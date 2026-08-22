import Foundation
import AppKit
import ApplicationServices

/// Stow's own doctor: the diagnostic surface for the facts that decide how the
/// reveal mechanism will behave, ported from AuthBar's `AuthDoctor` (same shape,
/// same one-corrective-action-per-finding discipline) but checking Stow's own
/// concerns rather than credentials.
///
/// Design section 10 names the one finding that earns this file its place:
/// per-item press-action coverage is the single fact that decides how often the
/// expensive reveal dance will have to run at all, and it is invisible without
/// a surface like this one.
///
/// Unlike `AuthDoctor`, none of Stow's checks are genuinely long-running I/O (no
/// network, no helper daemon IPC): Accessibility trust is a single syscall, the
/// point math is arithmetic over an already-measured `BarBudget`, while the
/// shortcut and boundary checks read their live runtime state. Only coverage walks another
/// process's accessibility tree per item, which is the one that can plausibly
/// stall against an unresponsive app, so it is the only one run inside the task
/// group with a running placeholder ahead of it. The others are computed synchronously
/// and are already correct by the time `findings` is first published.
@MainActor
final class BarDoctor: ObservableObject {

    enum Status: Equatable {
        case pass
        case warn(String)     // action label
        case info(String)
        case running
    }

    struct Finding: Identifiable, Equatable {
        let id: String
        var title: String
        var detail: String
        var status: Status
        var action: Action?

        enum Action: Equatable {
            /// Opens System Settings to the Accessibility pane, then asks macOS
            /// for the trust prompt.
            case grantAccessibility
        }
    }

    struct Summary: Equatable {
        let passCount: Int
        let totalCount: Int
        let issueCount: Int
        let fraction: Double
        let headline: String
        let hasWarning: Bool
    }

    @Published private(set) var findings: [Finding] = []
    @Published private(set) var running = false
    @Published private(set) var lastRun: Date?

    var passCount: Int {
        findings.filter { $0.status == .pass }.count
    }
    var warnCount: Int {
        findings.filter { if case .warn = $0.status { return true }; return false }.count
    }
    var anyRunning: Bool {
        running || findings.contains {
            if case .running = $0.status { return true }; return false
        }
    }

    var summary: Summary { Self.summary(for: findings) }

    /// Scores every displayed check. Informational rows are deliberately part of
    /// the denominator: partial, blocked, unavailable, or unmeasurable evidence
    /// must never produce a full ring or an "all healthy" headline.
    nonisolated static func summary(for findings: [Finding]) -> Summary {
        let passCount = findings.filter { $0.status == .pass }.count
        let warningCount = findings.filter {
            if case .warn = $0.status { return true }
            return false
        }.count
        let reviewCount = findings.filter {
            if case .info = $0.status { return true }
            return false
        }.count
        let runningCount = findings.filter { $0.status == .running }.count
        let totalCount = findings.count
        let fraction = totalCount == 0 ? 0 : Double(passCount) / Double(totalCount)

        let headline: String
        if runningCount > 0 || findings.isEmpty {
            headline = "Checking…"
        } else if warningCount == 1 {
            headline = "One check needs attention"
        } else if warningCount > 1 {
            headline = "\(warningCount) checks need attention"
        } else if reviewCount == 1 {
            headline = "One check needs review"
        } else if reviewCount > 1 {
            headline = "\(reviewCount) checks need review"
        } else {
            headline = "All checks passed"
        }

        return Summary(passCount: passCount, totalCount: totalCount,
                       issueCount: warningCount + reviewCount,
                       fraction: fraction, headline: headline,
                       hasWarning: warningCount > 0)
    }

    /// Runs every check. `screen` drives the per-display point math and the
    /// coverage scan; nil (no attached display) degrades both to an honest
    /// `.info` row rather than guessing at geometry that was never measured.
    func run(screen: NSScreen?, spacerWidth: CGFloat?,
             seamWindows: Set<CGWindowID> = []) async {
        guard !running else { return }
        running = true
        defer { running = false; lastRun = Date() }

        var results: [Finding] = [
            checkAccessibility(),
            checkPointMath(screen: screen, excluding: seamWindows),
            checkHotkeys(),
            checkSpacer(measuredWidth: spacerWidth),
            Finding(id: "coverage", title: "Press-action coverage",
                   detail: "walking the accessibility tree…",
                   status: .running, action: nil),
        ]
        findings = results

        let coverage = await checkCoverage(screen: screen, excluding: seamWindows)
        if let i = results.firstIndex(where: { $0.id == "coverage" }) {
            results[i] = coverage
        }
        findings = results
    }

    // MARK: - Checks

    /// Whether the app can synthesize a press at all. Without this grant both
    /// `RevealPath` cases are dead: `pressAction` needs it to read action names,
    /// and `revealOne` needs it to synthesize the click that opens the revealed
    /// item's menu. `BarState.blocked` exists for exactly this state.
    func checkAccessibility() -> Finding {
        if PressActionProbe.isTrusted {
            return Finding(id: "access", title: "Accessibility",
                           detail: "granted, both reveal paths are available",
                           status: .pass, action: nil)
        }
        return Finding(id: "access", title: "Accessibility",
                       detail: "not granted, no reveal path can run at all",
                       status: .warn("Grant"), action: .grantAccessibility)
    }

    /// The per-display arithmetic `BarBudget.arithmetic` already computes,
    /// surfaced here so headroom is visible without opening Arrange. `nil`
    /// screen (no attached display, or called before `NSScreen.main` resolves)
    /// is reported rather than defaulted to some other screen's geometry, since
    /// a defaulted screen would silently mismeasure a real multi-display setup.
    func checkPointMath(screen: NSScreen?, excluding seamWindows: Set<CGWindowID> = []) -> Finding {
        guard let screen else {
            return Finding(id: "pointmath", title: "Per-display point math",
                           detail: "no display to measure",
                           status: .info("n/a"), action: nil)
        }
        let barRect = BarScanner.menuBarRect(for: screen)
        let notch = BarScanner.notchWidth(for: screen)
        let scan = BarScanner.scan(menuBarRect: barRect)
        // Measured, not zeroed. An earlier version of this check hardcoded both AX
        // fields to 0 with a comment saying MenuWidthProbe had not landed yet; it
        // landed in the same batch, so the comment went stale within minutes and the
        // Doctor sat next to the panel on one screen reporting a DIFFERENT budget
        // for the same display. Two surfaces disagreeing is worse than either being
        // approximate, so both now read the same measurements.
        //
        // `?? 0` is still the right fallback and still means "not measurable": it
        // makes `usable` an upper bound rather than a claim, which is what the
        // caveat below reports whenever a field comes back nil.
        let appMenus = MenuWidthProbe.measureFrontmostAppMenuWidth()
        let systemTrailing = MenuWidthProbe.measureSystemTrailingWidth()
        let budget = BarBudget(
            screenWidth: screen.frame.width,
            appMenuWidth: appMenus ?? 0,
            notchWidth: notch,
            systemTrailingWidth: systemTrailing ?? 0,
            occupiedWidths: BarBudget.occupiedWidths(in: scan.items,
                                                      screenWidth: screen.frame.width,
                                                      excluding: seamWindows))

        // Name the unmeasured fields explicitly. "0 app menus" alone reads as a
        // measurement of zero, which would be a lie when the real state is that the
        // AX walk could not run.
        let unmeasured = [appMenus == nil ? "app menus" : nil,
                          systemTrailing == nil ? "system" : nil].compactMap { $0 }
        let caveat = unmeasured.isEmpty
            ? ""
            : "  (\(unmeasured.joined(separator: " and ")) not measurable, so usable is an upper bound)"
        return Finding(id: "pointmath", title: "Per-display point math",
                       detail: budget.arithmetic + caveat,
                       status: .pass, action: nil)
    }

    /// Uses the same window-number exclusion as BarSnapshot and Arrange. The
    /// expanded Stow boundary can be thousands of points wide; counting it as an
    /// app would make Doctor report impossible negative capacity while Stow is
    /// doing its job.
    nonisolated static func occupiedWidths(in items: [ObservedItem],
                                           excluding seamWindows: Set<CGWindowID>) -> [CGFloat] {
        items.filter(\.isOnScreen)
            .filter { !seamWindows.contains($0.windowNumber) }
            .map(\.frame.width)
    }

    func checkHotkeys() -> Finding {
        if EmergencyHotKey.shared.isRegistered {
            return Finding(id: "hotkey", title: "Emergency restore",
                           detail: "⌘⇧Esc is registered to Show Everything",
                           status: .pass, action: nil)
        }
        return Finding(id: "hotkey", title: "Emergency restore",
                       detail: "⌘⇧Esc could not be registered",
                       status: .warn("Restart Stow"), action: nil)
    }

    /// Confirms the shared HideController's real menu-bar boundary has a frame.
    /// A positive measured width proves the status item exists in the Window
    /// Server and that AppKit accepted its current spacer length.
    func checkSpacer(measuredWidth: CGFloat?) -> Finding {
        guard let measuredWidth, measuredWidth.isFinite, measuredWidth > 0 else {
            return Finding(id: "spacer", title: "Spacer effect",
                           detail: "boundary could not be measured",
                           status: .warn("Restart Stow"), action: nil)
        }
        return Finding(id: "spacer", title: "Spacer effect",
                       detail: "active, measured at \(Int(measuredWidth.rounded())) pt",
                       status: .pass, action: nil)
    }

    /// Which items answered `kAXPressAction`, the number that decides how often
    /// the expensive reveal path will have to run.
    ///
    /// Earlier, this refused to report a per-item number because
    /// `PressActionProbe.probe(pid:)` was called with `ObservedItem.ownerPID`,
    /// which on this OS is the Control Center process for every item without
    /// exception: a loop over `subjects` asked that one host the same question N
    /// times and would have reported its single answer N times over. Printing
    /// that as a per-item count would have been fabricated, so refusing was
    /// correct given what was actually being asked.
    ///
    /// What changed is that the real owning pid is now available.
    /// `BarItemOwners.identities()` asks each running application for its own
    /// `AXExtrasMenuBar` rather than asking the host that merely displays the
    /// item, retaining both visible and tucked positions, and returns the pid
    /// whose OWN app answers for that item. That is
    /// the pid `PressActionProbe.probe(pid:)` was always meant to receive, and
    /// this check now resolves it per item via `BarItemOwners.owner(of:in:)`
    /// before probing. Spacer mechanisms are excluded from the subject set. An
    /// eligible item whose owner cannot be resolved is reported as
    /// unresolved, never folded into either the zero-reveal or the reveal-one
    /// bucket, and a rate is never printed when nothing resolved at all.
    ///
    /// `PressActionProbe.path(for:)` is still not used here even though it is
    /// the production entry point: it caches by bundle ID, and a resolved
    /// owner's bundle ID can repeat across multiple items from the SAME app (a
    /// second status item from that app would hit the cache and report the
    /// first item's path), which would hide exactly the per-item variation this
    /// check exists to surface.
    func checkCoverage(screen: NSScreen?, excluding seamWindows: Set<CGWindowID> = []) async
        -> Finding {
        guard PressActionProbe.isTrusted else {
            return Finding(id: "coverage", title: "Press-action coverage",
                           detail: "needs Accessibility, see the grant above",
                           status: .info("blocked"), action: nil)
        }
        guard let screen else {
            return Finding(id: "coverage", title: "Press-action coverage",
                           detail: "no display to scan",
                           status: .info("n/a"), action: nil)
        }
        let barRect = BarScanner.menuBarRect(for: screen)
        let subjects = BarScanner.scan(menuBarRect: barRect).items
        guard !subjects.isEmpty else {
            return Finding(id: "coverage", title: "Press-action coverage",
                           detail: "no status items found",
                           status: .info("n/a"), action: nil)
        }

        let identities = BarItemOwners.identities()
        guard !identities.isEmpty else {
            return Finding(id: "coverage", title: "Press-action coverage",
                           detail: "UNMEASURABLE: no running application exposed an"
                               + " AXExtrasMenuBar identity, so no owning pid could be resolved",
                           status: .info("unmeasurable"), action: nil)
        }

        let split = Self.coverageSplit(subjects: subjects, identities: identities,
                                       screenWidth: screen.frame.width,
                                       excluding: seamWindows)
        var free = 0
        for (_, owner) in split.resolved {
            if PressActionProbe.probe(pid: owner.pid) == .pressAction { free += 1 }
        }

        guard let detail = Self.coverageDetail(free: free, resolved: split.resolved.count,
                                                unresolved: split.unresolved.count) else {
            return Finding(id: "coverage", title: "Press-action coverage",
                           detail: "UNMEASURABLE: none of \(subjects.count) item(s) resolved to"
                               + " an owning application",
                           status: .info("unmeasurable"), action: nil)
        }

        if free == split.resolved.count && split.unresolved.isEmpty {
            return Finding(id: "coverage", title: "Press-action coverage",
                           detail: detail, status: .pass, action: nil)
        }
        return Finding(id: "coverage", title: "Press-action coverage",
                       detail: detail, status: .info("partial"), action: nil)
    }

    /// Forwards to `BarItemOwners.split`, which is the single implementation.
    ///
    /// This and `Probe.splitByOwner` previously held identical bodies, with a test
    /// asserting the two copies agreed. The duplication was defended on the grounds
    /// that the logic is small and the files are separate, and that reasoning does
    /// not survive this project's own history: the same defect has already had to be
    /// fixed twice in two files on three separate occasions. One implementation is
    /// cheaper than a guard against divergence.
    static func splitByOwner(_ subjects: [ObservedItem], claims: [BarItemOwners.Owner])
        -> (resolved: [(item: ObservedItem, owner: BarItemOwners.Owner)], unresolved: [ObservedItem]) {
        BarItemOwners.split(subjects, claims: claims)
    }

    static func coverageSplit(subjects: [ObservedItem], identities: [BarItemOwners.Owner],
                              screenWidth: CGFloat, excluding seamWindows: Set<CGWindowID>)
        -> (resolved: [(item: ObservedItem, owner: BarItemOwners.Owner)], unresolved: [ObservedItem]) {
        BarItemOwners.coverageSplit(subjects: subjects, identities: identities,
                                    screenWidth: screenWidth, excluding: seamWindows)
    }

    /// Forwards to `BarItemOwners.coverageSummary`. See `splitByOwner` above.
    nonisolated static func coverageDetail(free: Int, resolved: Int, unresolved: Int) -> String? {
        BarItemOwners.coverageSummary(free: free, resolved: resolved, unresolved: unresolved)
    }
}
