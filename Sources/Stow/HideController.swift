import AppKit
import Combine
import SwiftUI

/// Hides and reveals the bar, which is the thing Stow exists to do.
///
/// Everything below rests on one measured fact: a status item can only push items
/// that are to its LEFT. The consequences are the whole design of this file.
///
/// Verified end to end by `Stow --hide` on a 2560pt bar with 8 third-party items:
///
///     seam landed at   x2330 (right of AuthBar at x2205)
///     expanded to      5016pt
///     result           8 pushed off, 0 unchanged
///
/// Two placements matter, and they are ORDERED. From the right edge inwards, the bar
/// must read: Stow's own token, then the seam, then everything the seam hides. Stow's
/// token has to be OUTSIDE the seam, because the first honest run of `--hide` pushed
/// Stow's own token off along with everything else, which left the user with nothing
/// left to click to get their bar back. A hide the user cannot undo is worse than no
/// hide at all, so the token's placement is a correctness requirement rather than a
/// cosmetic preference.
@MainActor
final class HideController: ObservableObject {

    /// What the bar is showing right now.
    ///
    /// The explicit `.revealed` state records that the user opened Stow, even though it
    /// has the same visible geometry as `.everything`.
    enum Presentation: Equatable, Sendable {
        /// Only apps assigned On Bar are visible. The resting state.
        case tidy
        /// Apps in Stow are temporarily visible because the user opened Stow.
        case revealed
        /// Everything on the bar, no seam expanded. What the user gets by pinning
        /// everything, and what Stow falls back to when it has nothing to hide.
        case everything
    }

    @Published private(set) var presentation: Presentation = .everything

    /// The leftmost position a seam can be placed at, measured while the seam rests.
    ///
    /// Published so the Arrange pane can name the apps below it. Two apps both sitting left
    /// of this cannot be separated into different zones, however the user sets them, because
    /// no seam can be placed between them. Nil until measured, or when a measurement was
    /// rejected as nonsense.
    @Published private(set) var placementFloor: CGFloat?

    /// Whether anything is currently off the bar. Kept because the panel's one primary
    /// control still reads as a two-way toggle, and because every existing caller asks
    /// this question rather than which of three states applies.
    var isHidden: Bool { presentation != .everything }

    /// Where phase timings go, when anyone is listening.
    ///
    /// Nil in the shipped UI, so an apply pays nothing for instrumentation. Set by `--apply`,
    /// which is the surface that has to answer "where does the time actually go".
    var timingSink: ((String) -> Void)?

    /// The last placement per boundary that actually satisfied a request.
    ///
    /// Seeds the fast path in `moveCut`. Only written when the search genuinely found a slot
    /// right of its target, so a placement that was already wrong can never be retried as
    /// though it had worked.
    ///
    /// Not persisted. It describes where a seam sits on THIS bar in THIS session, and the bar's
    /// shape changes whenever an app launches or quits, so carrying it across launches would
    /// seed the fast path with a stale answer that looks authoritative.
    private var lastGoodPlacement: [SpacerItem.Boundary: Int] = [:]

    /// Search bounds for the placement preference.
    ///
    /// The low bound is 1 rather than 0 because 0 is the extreme right edge, where the seam
    /// competes with Control Center's own run for the outermost slot. The high bound is past
    /// the leftmost reachable slot on the widest bar measured, since a value beyond the last
    /// slot clamps rather than failing.
    private static let minimumPlacement = 1
    private static let maximumPlacement = 900

    /// How many probes the search may spend. Bisecting 1...900 needs about ten to converge
    /// exactly, but the preference resolves to a coarse SLOT, so the last few steps land in the
    /// slot already found. Five is where the measured mapping stops changing.
    private static let maximumProbes = 5

    /// Widest a seam can measure and still count as RESTED.
    ///
    /// A resting seam measures about 17pt: the claimed length plus roughly 5pt of chrome per
    /// side. A pushing one measures about 5,016pt, the window server's clamp on a 10,000pt
    /// request. Anything under this is at rest by any reading, and the gap between the two is
    /// three orders of magnitude, so the exact value is not delicate.
    private static let restingWidthCeiling: CGFloat = 100

    /// Where the seam is parked when apps are arranged around it.
    ///
    /// The leftmost slot the placement preference can express, which is its LARGEST value: a
    /// larger preference is never further right, measured by sweeping. Parking here is what makes
    /// pinned apps cost nothing to arrange, because they are already right of it.
    private static let parkedPlacement = maximumPlacement

    /// How far right of its target a remembered placement may land and still be reused.
    ///
    /// One item's typical width. Wider than this and the seam is hiding materially less than
    /// asked, which is worth a full search to fix; within it, the difference is a fraction of
    /// one icon and not worth four extra status-item recreations.
    private static let fastPathSlack: CGFloat = 40

    /// Measured placement floors, keyed on display frame. See `prepareAndVerifyPlacement`.
    private var floorByDisplay: [String: CGFloat] = [:]

    /// The single seam. Kept for the process lifetime so hidden apps cannot be stranded.
    private var seams: [SpacerItem.Boundary: SpacerItem] = [:]

    /// How wide to make a seam when it is pushing. A request, not a guarantee: the window
    /// server clamped a 10,000pt request to 5,016pt in the verified run, and honoured the
    /// push regardless. Asking for more than needed is safe; asking for exactly the
    /// measured shortfall would not be, since the clamp is not a documented number.
    private static let pushWidth: CGFloat = 10_000

    /// Places Stow's own menu bar token outside the seam.
    ///
    /// MUST run before the token is created, which for a `MenuBarExtra` means before the
    /// scene body is first evaluated. AppKit reads this preference when the item is made;
    /// writing it later takes effect only on the next launch.
    ///
    /// The key names `Item-0` because that is the identity AppKit assigns a status item
    /// with no explicit `autosaveName`, which is what `MenuBarExtra` creates. Confirmed on
    /// this machine: writing `Item-0` and relaunching moved Stow's token from x1761 to
    /// x2318, so this is genuinely the token's own key and not a guess.
    ///
    /// The value is smaller than either seam's, which is what puts the token furthest
    /// right of the three. That ordering is a correctness requirement: a token inside a
    /// seam is pushed off by its own hide, leaving no control to undo it.
    static func placeOwnTokenOutsideSeam() {
        UserDefaults.standard.set(tokenOffsetFromRightEdge,
                                  forKey: "NSStatusItem Preferred Position Item-0")
    }

    /// Stow's token sits further right than either seam, so a hide never takes away the
    /// control that undoes it.
    ///
    /// `nonisolated` because it is a plain Sendable constant with no actor state behind
    /// it, which lets the placement-ordering test read it without hopping to the main
    /// actor. Plain `nonisolated`, verified by the compiler, rather than
    /// `nonisolated(unsafe)`, which would only assert it.
    nonisolated static let tokenOffsetFromRightEdge = 2

    /// Creates the seam at rest, so it is placed and ready before any hide.
    ///
    /// At launch rather than on first hide, deliberately. Placement is read from a
    /// preference at CREATION time, so a seam created lazily during the first hide would
    /// be placed correctly but would also appear in the bar at the moment the user asked
    /// for items to disappear, which reads as Stow adding items while claiming to remove
    /// them.
    func prepare() {
        for boundary in SpacerItem.Boundary.allCases where seams[boundary] == nil {
            SpacerItem.place(boundary)
            seams[boundary] = SpacerItem(boundary: boundary, state: .tidy)
        }
    }

    /// The seam for the boundary, creating it if needed.
    private func seam(_ boundary: SpacerItem.Boundary) -> SpacerItem? {
        prepare()
        return seams[boundary]
    }

    /// Creates the seam AND verifies it can actually push, correcting it if not.
    ///
    /// The stored placement cannot be trusted on its own. It names a SLOT, and that slot
    /// only sits right of the items needing a push while the bar keeps the shape it had
    /// when the value was written. Two ordinary things invalidate it: the user quitting
    /// or launching a menu bar app, and any diagnostic that searched for a slot.
    ///
    /// Observed on this machine after a `--cut` run left the stored value at 323: the
    /// seam came back at x7, left of the entire bar, where expanding it pushes nothing.
    /// A hide then does nothing at all, with no error anywhere to explain it.
    ///
    /// So verify rather than trust: place, measure, and if the seam is not right of the
    /// rightmost item Stow can push, move it there. One measurement in the good case,
    /// self-repairing in the bad one.
    ///
    /// Control Center is excluded from "rightmost", not Apple items in general: its six
    /// visible items all share the bundle id `com.apple.controlcenter`, so none of them can
    /// be addressed on its own, and placing the seam right of one it does not mean to hide
    /// would push more than was asked for. A live test moved the Apple-owned Kerberos extra
    /// with the same command-drag `ItemMover` uses, x1153 to x1228, so an individually
    /// addressable Apple item is not exempt here.
    ///
    /// - Parameter repairStrandedSeam: whether to move a stranded seam to safety. Pass FALSE
    ///   when the caller is about to place the seam itself, which is the repair by another
    ///   name. `applyPersistedPlan` does exactly that, and paying for both was measured at
    ///   2.6-3.2s per apply: a full search to park the seam somewhere harmless, immediately
    ///   followed by another search to put it where it belongs. The two searches also aimed at
    ///   different targets, this one at the rightmost app on the bar and the real one at the
    ///   rightmost app that must be HIDDEN, so the remembered placement was overwritten with a
    ///   differently-aimed answer and the fast path could never hit.
    @discardableResult
    func prepareAndVerifyPlacement(repairStrandedSeam: Bool = true) -> CGFloat? {
        prepare()

        // Force the seam to rest before measuring anything.
        //
        // A seam left expanded from a previous session, or by a bug, measures a left edge of
        // about -2700 on a 2560pt bar, because the item is ~5000pt wide. Every comparison
        // below would then be against a number that describes nothing, which is exactly how a
        // seam once ended up spanning the whole bar and pushing every item off it.
        for seam in seams.values { seam.expand(toPush: SpacerItem.restingLength) }
        presentation = .everything

        guard let tucked = seams[.tucked],
              let cut = tucked.awaitMeasuredFrame()?.minX else { return nil }

        let ownBundle = Bundle.main.bundleIdentifier
        let pushable = BarItemOwners.refreshCache().filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID) && $0.bundleID != ownBundle
        }

        // Measure the placement floor HERE, and only here: the seam has just been rested
        // and `awaitMeasuredFrame` has already spun the run loop, so the bar has had a chance
        // to lay out with everything visible.
        //
        // Both halves of that matter. A probe created while a seam is expanded is pushed off
        // the bar and measures a large negative position: x-3128 when tried. And a probe
        // created while the bar is still sparse from a hide lands far RIGHT, which is worse
        // than useless: a floor right of every app marks every app unzonable, and the board
        // then captions every single tile "macOS limit", which is what it did.
        // Measured ONCE per display configuration, not once per apply.
        //
        // The probe creates a real status item and waits for the window server, and it was
        // measured costing anywhere from 0.57s to 3.06s on a single apply, the high end being a
        // wait that timed out. The floor is a property of the DISPLAY, not of what is currently
        // hidden: it is the leftmost slot macOS will place a new item at. So it is re-measured
        // when the display setup changes and reused otherwise.
        //
        // Keyed on the frame rather than the name, because the same monitor at a different
        // resolution is a different bar with a different floor.
        let displayKey = NSScreen.main.map { "\($0.frame)" } ?? "none"
        if let cached = floorByDisplay[displayKey] {
            placementFloor = cached
        } else {
            placementFloor = Self.plausibleFloor(SpacerItem.measurePlacementFloor(),
                                                 rightmostApp: pushable.map(\.axLeftEdge).max())
            // Only a measurement that passed the plausibility check is worth keeping. Caching a
            // nil would make one bad probe permanent for the session, and a nil floor makes the
            // board caption every tile "macOS limit".
            if let floor = placementFloor { floorByDisplay[displayKey] = floor }
        }

        guard repairStrandedSeam else { return cut }
        guard let rightmost = pushable.map(\.axLeftEdge).max() else { return cut }
        guard cut <= rightmost else { return cut }

        // Same clearance as every other aim, so a repair and a real placement cannot disagree
        // about where "right of this app" is.
        return moveCut(toSitRightOf: rightmost + Self.pushClearance)
    }

    /// Rejects a floor measurement that cannot be describing a real limit.
    ///
    /// Two rejections, both from observed failures rather than caution. A non-positive floor
    /// means the probe was itself pushed off the bar: measured at x-3128 while a seam was
    /// expanded. A floor to the RIGHT of every app means the bar was sparse when it was
    /// probed, so the probe could land somewhere no ordinary app sits; believing it marks
    /// every app as unzonable, which is never a useful answer and was visibly wrong on the
    /// board.
    ///
    /// Returning nil rather than a guess: the plan treats nil as "not known", which reports
    /// nothing, and reporting nothing is the honest outcome of a failed measurement.
    /// `nonisolated` because it is pure arithmetic over its own arguments, which lets the
    /// tests exercise both rejections without a status bar or a main-actor hop.
    nonisolated static func plausibleFloor(_ measured: CGFloat?,
                                           rightmostApp: CGFloat?) -> CGFloat? {
        guard let measured, measured > 0 else { return nil }
        guard let rightmostApp else { return measured }
        return measured <= rightmostApp ? measured : nil
    }

    // MARK: - the three states

    /// Apps assigned On Bar only.
    func tidy() {
        prepare()
        seams[.tucked]?.expand(toPush: Self.pushWidth)
        presentation = .tidy
    }

    /// Temporarily shows the apps in Stow.
    func reveal() {
        prepare()
        seams[.tucked]?.expand(toPush: SpacerItem.restingLength)
        presentation = .revealed
    }

    /// Everything on the bar. The seam rests and pushes nothing.
    func showEverything() {
        prepare()
        for seam in seams.values { seam.expand(toPush: SpacerItem.restingLength) }
        presentation = .everything
    }

    /// The everyday gesture: tidy becomes revealed, anything else becomes tidy.
    ///
    /// Deliberately does NOT cycle through all three. `everything` is a configuration
    /// outcome, reached by pinning everything, not a state to land in by pressing a button
    /// twice; a three-way cycle would make one press in three appear to do nothing.
    func toggle() {
        presentation == .tidy ? reveal() : hide()
    }

    /// Hides per the current plan, but never at the cost of hiding Stow's own control.
    ///
    /// A migrated layout can ask the seam to cross the old Rail token position. The seam then
    /// pushes Stow's token off-screen too, leaving no control capable of undoing the hide.
    /// Falling back to everything visible is the only recoverable result in that geometry.
    func hide() {
        tidy()
        keepOwnTokenReachable()
    }

    /// Whether the owning-app walk can still see Stow's token on the visible bar.
    ///
    /// Split out as pure logic because the live regression is destructive: a false result is
    /// the state where the user has no icon left to click.
    nonisolated static func ownTokenIsVisible(in identities: [BarItemOwners.Owner],
                                              ownBundle: String) -> Bool {
        identities.contains { $0.bundleID == ownBundle && $0.axLeftEdge > 0 }
    }

    /// Restores the bar if a seam swept Stow's own token away.
    @discardableResult
    private func keepOwnTokenReachable() -> Bool {
        awaitBarToSettle(timeout: 0.5)
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let identities = BarItemOwners.refreshIdentityCache()
        guard !ownBundle.isEmpty,
              Self.ownTokenIsVisible(in: identities, ownBundle: ownBundle) else {
            showEverything()
            return false
        }
        return true
    }

    /// Legacy seam-placement diagnostic retained for command-line measurements.
    ///
    /// Without this, quitting Stow silently undoes every choice. A fresh process creates
    /// seams at rest, so the bar comes back fully visible and every zone the user set is a
    /// lie until they open the pane and press Apply again.
    ///
    /// Reads the same two sources the Arrange pane reads: `Config`'s per-bundle zones for
    /// intent, and `BarHomes` for where each app belongs. `BarHomes` is what makes this
    /// possible at all for an app that is currently hidden, whose live position says
    /// nothing about where it should sit.
    ///
    /// - Parameter config: the persisted policy. Passed in rather than read here so this
    ///   type keeps knowing nothing about how configuration is stored.
    @discardableResult
    func applyPersistedPlan(from config: Config) -> CGFloat? {
        // Phase timings, so the cost of an apply is measured rather than guessed.
        //
        // This exists because the cost was guessed twice and wrongly both times. A drag was
        // reported slow, the placement search was blamed, and replacing that search with a
        // cached map changed the measured total from 15.1s to 16.0s: no improvement at all.
        // Attributing time to a phase without measuring it is how that happened.
        //
        // Printed only under `--apply`, via `timingSink`, so the shipped UI path pays nothing
        // but the diagnostic reports the real breakdown.
        let began = Date()
        var lastMark = began
        func mark(_ label: String) {
            let now = Date()
            timingSink?("  \(label): \(String(format: "%.2f", now.timeIntervalSince(lastMark)))s")
            lastMark = now
        }

        // No stranded-seam repair: the placement below IS the repair, and doing both meant two
        // searches per apply aimed at two different targets.
        prepareAndVerifyPlacement(repairStrandedSeam: false)
        mark("rest + floor           ")

        // Re-record homes NOW, with the seam rested and every app visible.
        //
        // Without this the plan is computed from positions recorded before the seams existed,
        // and each seam adds ~17pt to the bar, so every stored home is stale by about one
        // item's width. Measured: Vendor Agent's home read 2028 while the app actually sat at 2045, so
        // the seam was placed right of 2028, which is LEFT of Vendor Agent, and Vendor Agent stayed on the bar
        // while being set to Tucked. A 17pt error is the same order as the gap between two
        // adjacent apps, so it is not a rounding concern, it decides which side of the seam an
        // app lands on.
        // Reuses the walk `prepareAndVerifyPlacement` just took, rather than repeating it.
        //
        // Both want the same thing: every app's position with the bar rested and everything
        // visible. That call rests the seams, spins the run loop, and walks; this ran
        // immediately afterwards and walked again against an unchanged bar. At 0.965s a walk,
        // that was a second of a frozen board for a list Stow already had.
        let ownBundle = Bundle.main.bundleIdentifier
        BarHomes.record(BarItemOwners.lastKnownClaims.filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID) && $0.bundleID != ownBundle
        })
        mark("owner walk + homes    ")

        let zones: (String) -> Zone = { config.zone(forBundleID: $0) }
        let plan = BarPlan.outcome(candidates: currentCandidates(), zones: zones)
        mark("plan                  ")

        // FAIL OPEN. A seam is geometric: it pushes every item to its left. If the plan says
        // that includes a pinned app, applying it anyway hides something the user did not
        // choose. The Arrange pane used to warn
        // about that and proceed; the live result was an apparently empty menu bar.
        guard plan.isSafeToApply else {
            showEverything()
            mark("unsafe plan refused   ")
            timingSink?("  TOTAL: \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
            return measuredCutX()
        }

        guard plan.tuckedBoundaryX != nil else {
            // Nothing is hidden, so leave the bar alone rather than expanding
            // a seam that has nothing to push.
            showEverything()
            return measuredCutX()
        }

        // AIM PAST THE APP'S OWN WIDTH, exactly as the correction pass does.
        //
        // `tuckedBoundaryX` is the rightmost hidden app's LEFT edge, because `homeX` is an
        // `axLeftEdge`. A seam that lands just right of a left edge sits ON the app, not past
        // it, so it does not push it. That is a systematic shortfall of one item's width, not
        // an occasional miss, and it is why `correctPlacementIfWrong` almost always found work
        // to do: the first placement was aimed short by construction and the correction was
        // silently paying for it. Measured, the correction cost 2.4-4.5s on every single apply.
        //
        // Both calls now aim the same way, which also makes the remembered placement in
        // `moveCut` reusable: apply N and apply N+1 ask the same question, so the fast path can
        // actually hit instead of testing a placement that was aimed differently.
        var landed: CGFloat?
        if let target = plan.tuckedBoundaryX {
            landed = moveCut(toSitRightOf: target + Self.pushClearance, boundary: .tucked)
        }
        mark("move tuck seam        ")

        tidy()
        mark("tidy                  ")

        // VERIFY, then correct once.
        //
        // The search measures candidate slots against the bar as it is DURING the search, and
        // the bar reflows as seams are created and destroyed, so a slot that measured right of
        // the target can end up left of it. Measured: the tuck seam settled at x1991 with its
        // right edge near x2008 while the app it had to push sat at x2045, so a Tucked app
        // stayed on the bar with no error anywhere.
        //
        // One pass, not a loop. A second correction from a third measurement would be chasing
        // a bar that is still moving, and a wrong-by-one-slot seam hides slightly less than
        // asked, which is visible and recoverable. Looping risks never settling.
        correctPlacementIfWrong(zones: zones)
        mark("correction pass       ")
        keepOwnTokenReachable()
        mark("token safety          ")
        timingSink?("  TOTAL: \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
        return landed ?? measuredCutX()
    }

    /// Checks that every app which should be off the bar actually is, and moves the tuck seam
    /// once more if not.
    ///
    /// Reads LIVE claims rather than remembered homes, because the question is about the bar as
    /// it stands now: which apps are still visible that the zones say should not be.
    private func correctPlacementIfWrong(zones: (String) -> Zone) {
        let ownBundle = Bundle.main.bundleIdentifier
        let stillVisible = BarItemOwners.refreshCache().filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID)
                && $0.bundleID != ownBundle
                && zones($0.bundleID) != .pinned
        }
        guard let rightmostWrong = stillVisible.map(\.axLeftEdge).max() else {
            // Nothing to fix, so the walk just taken describes the bar's FINAL state and the
            // caller can reuse it instead of paying for another. This is the common case now
            // that every aim carries the same clearance.
            return
        }

        // A NUDGE was tried here and reverted. It stepped the placement preference down one
        // slot at a time, which is directionally right and much cheaper: the correction fell
        // from 2.2-3.7s to 0.6-1.0s. It also broke placement. Measured over three runs on an
        // unchanged configuration, `--apply` went from 0, 0, 0 unexplained mismatches to 1-3,
        // because stepping right sweeps whatever sits in the gap and the step lands wherever
        // the window server puts it rather than at the leftmost slot that qualifies. The
        // bisection picks the leftmost qualifying slot, which is the minimum sweep, and that
        // property is what keeps pinned apps on the bar. Do not trade it for the second.
        //
        // Aim past the app's own right edge, not its left. A seam whose own right edge lands
        // exactly at the target's left edge does not push it, which is the off-by-one-item
        // error this whole correction exists to undo.
        _ = moveCut(toSitRightOf: rightmostWrong + Self.pushClearance, boundary: .tucked)
        tidy()

        // Re-walk, so the cache describes the bar as it FINISHED rather than as it was before
        // this correction moved a seam. Without this the caller's reuse would be reading
        // positions from one state earlier, and `BarHomes.record` matches claims against live
        // window frames within 4pt, so a stale position records no home at all.
        BarItemOwners.refreshCache()
    }

    /// How far past a target to aim, in points.
    ///
    /// One item's typical width. The placement preference resolves to a coarse slot, so aiming
    /// exactly at a target regularly lands the seam in the slot just short of it.
    /// Internal rather than private because `BarPlan` must predict what gets swept against the
    /// SAME aim the placement uses. A plan computed without it under-reports collateral by one
    /// item's width, which is a warning that does not fire for an app that does get hidden.
    static let pushClearance: CGFloat = 34

    /// Every app Stow can act on, with the best position known for each.
    ///
    /// Shared by the persisted-plan restore and the diagnostics so both reason about the
    /// same set, including apps that are currently pushed off the bar and therefore have
    /// no meaningful live position.
    func currentCandidates() -> [BarPlan.Candidate] {
        Self.candidates(identities: BarItemOwners.cachedIdentitiesList(),
                        liveClaims: BarItemOwners.lastKnownClaims,
                        homes: BarHomes.all,
                        ownBundle: Bundle.main.bundleIdentifier)
    }

    /// The pure logic behind `currentCandidates()`, split out so a test can drive every
    /// branch without a window server or an accessibility grant.
    ///
    /// LIVE positions win over remembered ones.
    ///
    /// A remembered home is stale the moment the bar's shape changes, and every seam Stow
    /// creates changes it by ~17pt. Measured: Vendor Agent's stored home read 2028 while the app
    /// actually sat at 2045, so a seam placed right of 2028 landed LEFT of Vendor Agent and Vendor Agent
    /// stayed on the bar while set to Tucked. A 17pt error is the same order as the gap
    /// between two adjacent apps, so it decides which side of a seam an app falls on.
    ///
    /// Remembered homes are still needed, and only for the apps that make them necessary:
    /// one currently pushed off the bar has no live position at all, because
    /// `BarItemOwners.claims()` drops anything at a non-positive x. So live where possible,
    /// remembered where not.
    ///
    /// A THIRD source covers the app neither of those two knows about: `identities` reports
    /// who owns a bar item independent of position, so an app pushed off the bar before Stow
    /// ever recorded a home for it, exactly OneDrive's situation at x-8958, still shows up
    /// here. Live and remembered both come up empty for that app, so it enters the list with
    /// `isPushable: false`: a real, zoneable candidate that simply cannot be placed yet,
    /// rather than one silently missing from the board. A stranded identity reporting the
    /// `x = -1` sentinel is excluded, because that value names "no position", not a push, and
    /// treating it as a candidate would offer to zone an item that was never really seen.
    nonisolated static func candidates(identities: [BarItemOwners.Owner],
                                       liveClaims: [BarItemOwners.Owner],
                                       homes: [String: CGFloat],
                                       ownBundle: String?) -> [BarPlan.Candidate] {
        var homes = homes.filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.key) && $0.key != ownBundle
        }
        for claim in liveClaims
        where !VisibleRowIdentity.cannotBeAddressedIndividually(claim.bundleID)
            && claim.bundleID != ownBundle
            && !claim.bundleID.isEmpty {
            homes[claim.bundleID] = claim.axLeftEdge
        }

        var result = homes
            .map { BarPlan.Candidate(bundleID: $0.key, homeX: $0.value, isPushable: true) }

        let stranded = Set(identities
            .filter {
                !$0.bundleID.isEmpty
                    && $0.bundleID != ownBundle
                    && !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID)
                    && homes[$0.bundleID] == nil
                    && BarItemOwners.isPushedOffScreen($0.axLeftEdge)
            }
            .map(\.bundleID))
        result += stranded.sorted().map {
            BarPlan.Candidate(bundleID: $0, homeX: 0, isPushable: false)
        }

        return result.sorted { $0.homeX > $1.homeX }
    }

    /// The apps Stow is hiding right now, for the panel's sub-bar.
    ///
    /// Built from the persisted zones and `BarHomes`, NOT from a bar scan, because a hidden
    /// item is not in a scan: `BarItemOwners.claims()` filters to `x > 0` and a pushed item
    /// reports a large negative position, so it vanishes from the walk entirely. Measured: with
    /// Vendor Agent tucked, `--open Vendor Agent` could not find it among the known owners at all.
    ///
    /// The pid comes from the bundle instead, which is what makes the item pressable. Verified
    /// on that same hidden app: its AX element sat at x-3036 and pressing it opened its menu.
    ///
    /// An app that is not running is skipped. It cannot be pressed and it is not on the bar, so
    /// offering it would be offering nothing.
    func hiddenApps(from config: Config) -> [HiddenApp] {
        currentCandidates().compactMap { candidate in
            let zone = config.zone(forBundleID: candidate.bundleID)
            guard zone != .pinned else { return nil }
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: candidate.bundleID).first
            else { return nil }
            return HiddenApp(bundleID: candidate.bundleID,
                             name: running.localizedName ?? candidate.bundleID,
                             icon: running.icon,
                             zone: zone,
                             pid: running.processIdentifier)
        }
        .sorted { lhs, rhs in
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Where the tucked boundary sits, as a position on the bar.
    ///
    /// Reports the seam's RESTING position, even while items are hidden. Reading the live
    /// frame instead is wrong in a way that reaches the user: an expanded seam is about
    /// 5,000pt wide, so its left edge measures around -3,160 on a 2560pt bar, and the pane
    /// dutifully printed "cut at x-3,160". That number describes nothing a user can act on.
    ///
    /// So the resting position is remembered whenever it is legitimately measured, and that
    /// is what every caller gets.
    func measuredCutX() -> CGFloat? {
        if presentation == .tidy { return restingCutX }
        if let live = seams[.tucked]?.measuredFrame()?.minX {
            restingCutX = live
            return live
        }
        return restingCutX
    }

    /// The tucked seam's last known position while at rest. See `measuredCutX()`.
    private var restingCutX: CGFloat?

    /// Blocks until the tucked seam is resolvable, and returns its measured left edge.
    ///
    /// A status item's window does not reach `CGWindowListCopyWindowInfo` at a predictable
    /// moment after creation, so a measurement taken in the same tick as `prepare()` reads
    /// a world the seam is not in yet. That is exactly what made `--cut` report "the cut
    /// could not be measured" on a seam that existed.
    ///
    /// DIAGNOSTIC ONLY. It spins a nested run loop, which is correct for a CLI mode that
    /// has no other way to let AppKit lay the item out, and wrong for the UI, where the
    /// window server has already reported the seam long before any pane asks. The UI path
    /// uses `measuredCutX()` and treats nil as "not placed yet", which the next rescan
    /// resolves.
    @discardableResult
    func awaitSeamPlacement() -> CGFloat? {
        prepare()
        return seams[.tucked]?.awaitMeasuredFrame()?.minX
    }

    /// A seam's measured width right now, for the Doctor and for diagnostics. Nil when it
    /// has not been created or cannot yet be told apart from every other status item.
    func measuredSeamWidth(_ boundary: SpacerItem.Boundary = .tucked) -> CGFloat? {
        seams[boundary]?.measuredFrame()?.width
    }

    /// The seam's window number, so bar listings can exclude Stow's machinery.
    func seamWindowNumbers() -> Set<CGWindowID> {
        var out: Set<CGWindowID> = []
        for seam in seams.values {
            // Measuring first: the window number is only resolvable once the window server
            // has actually reported the seam, and a caller may ask before then.
            _ = seam.measuredFrame()
            if let number = seam.windowNumber { out.insert(number) }
        }
        return out
    }

    /// The TUCKED boundary's live window number, or nil if it has none yet.
    ///
    /// Exists for temporary reveal, which has to express "put this item on the visible side of
    /// the tucked seam" and then "put it back". Both are `ItemMover.Destination` values relative
    /// to this window, so the caller needs the number rather than the seam object.
    ///
    /// Measured first, like `seamWindowNumbers()`: the number only resolves once the window
    /// server has reported the seam, and at launch a caller can easily ask before then.
    func tuckedSeamWindow() -> CGWindowID? {
        guard let seam = seams[.tucked] else { return nil }
        _ = seam.measuredFrame()
        return seam.windowNumber
    }

    // MARK: - the seam positions

    /// Moves the cut line so it sits immediately to the RIGHT of `targetX`, meaning
    /// the item at `targetX` will be hidden and whatever sits right of the new cut
    /// will not.
    ///
    /// A bounded binary search over the placement preference, because that preference is a
    /// SLOT INDEX and not a pixel offset. Measured on a 2560pt bar by sweeping ten values:
    ///
    ///     pref 1          ->  x2323
    ///     pref 20 … 160   ->  x2263      one slot, five different values
    ///     pref 240        ->  x2221
    ///     pref 320        ->  x2070
    ///     pref 480        ->  x1966
    ///     pref 640        ->  x1810
    ///
    /// Monotonic: a larger value is never further right. No formula converts points to a
    /// preference, but monotonicity makes the position searchable.
    ///
    /// WHY A SEARCH AND NOT A CACHED MAP. A cached slot map was tried and removed. It measured
    /// the placement-to-position mapping with a throwaway probe item and then applied the
    /// result to the real seam, and placements DO NOT TRANSFER ACROSS AUTOSAVE IDENTITIES:
    /// measured on one unchanged bar, `pref 1` landed at x1160 under one name and x1516 under
    /// another, a 356pt disagreement. Two runs of the same measurement also found five slots
    /// and seven slots, because creating and destroying probe items perturbs the bar being
    /// measured. It was also no faster in practice: first apply 8.25s, second apply 8.26s, so
    /// the cache never stayed warm, and end to end it measured 16.02s against this search's
    /// 15.09s. A search moves the REAL seam, so it cannot have an identity-transfer problem.
    ///
    /// EVERY probe measures at the seam's RESTING width, never at its pushing width, and that
    /// is a correctness requirement rather than a tidiness one. An expanded seam is about
    /// 5,000pt wide, so its left edge is a large negative number: measured at x-2714 on a
    /// 2560pt bar. Comparing that against a target is meaningless, so a search run while the
    /// bar was hidden compared garbage at every step and settled on a seam spanning the whole
    /// bar. The hidden state is restored after the search, not carried through it.
    ///
    /// Applies the user's zones by MOVING APPS around a stationary seam, instead of moving the
    /// seam to fit the apps.
    ///
    /// The alternative to `applyPersistedPlan`, and the point of `BarArranger`. That path
    /// searches for a slot and costs a measured 5.6s per drop; this one moves only the apps
    /// that are on the wrong side, at 0.2-1.0s each, and costs nothing for apps already
    /// correct.
    ///
    /// Sequence matters and every step is load-bearing:
    ///
    ///   1. REST the bar. Moves need every item visible: a pushing seam is ~5,000pt and sweeps
    ///      everything to its left off the visible bar, where an app can neither be found nor
    ///      verified. Measured against a live bar, one move landed out of six and the failures
    ///      all named the wrong cause.
    ///   2. Arrange, relative to the seam's own window.
    ///   3. Restore the hidden state, so the user sees what they had.
    ///
    /// - Returns: what the arrange did, so a caller can report it rather than assume it worked.
    @discardableResult
    func arrangeByMovingItems(from config: Config) -> BarArranger.Outcome {
        // Timed from HERE, before `prepare()`, because the log's `cost=` is the only signal the
        // launch caller leaves and it should cover everything this function does. The entry work is
        // where a failed arrange spends its seconds: `awaitMeasuredWidth` 3.0s, `awaitBarToSettle`
        // 1.5s, and when the seam is not already parked a reposition plus a SECOND
        // `awaitMeasuredWidth`, so about 7.5s before the second guard is reached. Not "either guard":
        // the first sits above all of it and is reached in roughly no time, as well as being
        // unreachable.
        let began = Date()
        prepare()
        let previous = presentation

        // Everything visible, with the seam at rest.
        //
        // And WAIT for the resting width to actually take effect, which is not the same as
        // waiting for the window to be findable. `showEverything` only sets `length`; the window
        // server applies it a beat later, and `awaitMeasuredFrame` returns as soon as the window
        // resolves, which it already had. So reading here found the seam still ~5,000pt wide and
        // spanning off-screen, `BarArranger` filtered it out as not a real item, and every
        // arrange failed with "the seam is not on the visible bar" while the seam was right
        // there. `awaitMeasuredWidth` exists precisely for this distinction.
        showEverything()
        // UNREACHABLE, and kept only because the dictionary lookup is optional.
        //
        // `prepare()` ran at the top of this function and again inside `showEverything()` just above,
        // and it assigns a seam for every boundary that has none. `SpacerItem.init` is non-failable
        // and `seams` is never emptied, so there is no path here. An earlier version of this guard
        // carried a paragraph of measured history about a launch arrange failing silently; that
        // history belongs to the OTHER exit below, which can genuinely fire. Still routed through
        // `failedOutcome` so that if someone ever does clear `seams`, this behaves like every other
        // exit rather than becoming the silent one again.
        guard let seam = seams[.tucked] else {
            return failedOutcome(reason: "the tucked seam does not exist",
                                 from: previous, began: began, config: config)
        }
        _ = seam.awaitMeasuredWidth(satisfying: { $0 < Self.restingWidthCeiling })

        // WAIT FOR THE SWEPT ITEMS TO COME BACK, which the seam's own width does not tell you.
        //
        // `showEverything` rests the seams, and `awaitMeasuredWidth` confirms the SEAM is narrow
        // again, but the items it was hiding return over the following moments as the bar
        // reflows. Arranging before they arrive means they are simply not in the scan, so they
        // are skipped, and then `tidy` sweeps them: measured, a second arrange run immediately
        // after a first saw 2 apps where the bar had 7, and at launch `com.example.vendoragent` was
        // missed this way and swept.
        //
        // Polls for the COUNT to stop changing rather than for a fixed duration, because how
        // long a bar takes to reflow depends on how many items were hidden.
        awaitBarToSettle()
        // PARK THE SEAM AT THE FAR LEFT, once, and then never move it again.
        //
        // This is the design, not an optimisation, and getting it wrong swept the bar twice
        // while wiring this up. Which side of the seam an app must sit on is decided by its
        // zone, so where the seam sits decides how many apps have to MOVE:
        //
        //   - Seam at the far LEFT of the run: every pinned app is already right of it, so
        //     pinned apps cost nothing and only the tucked ones move. That is the minimum work
        //     and the minimum exposure to a refused move.
        //   - Seam anywhere RIGHT of the apps: every pinned app needs moving, and any one of
        //     those moves that the OS refuses leaves its app left of the seam, where `tidy`
        //     sweeps it off. Measured live with the seam left wherever a previous placement had
        //     put it: five pinned apps swept, then four, depending on which moves happened to
        //     land.
        //
        // So the seam is parked at the leftmost placement the preference can express, which is
        // the LARGEST value: measured, a larger preference is never further right. Done only
        // when it is not already there, so a repeat arrange costs no reposition.
        if seam.currentPlacement != Self.parkedPlacement {
            _ = seam.reposition(placement: Self.parkedPlacement,
                                length: SpacerItem.restingLength)
            _ = seam.awaitMeasuredWidth(satisfying: { $0 < Self.restingWidthCeiling })
        }
        // MEASURE, then check. Same reason the closure below measures: `windowNumber` reports only
        // what `measuredFrame()` last resolved, so a bare read here would fail an arrange whose
        // seam exists and has simply never been asked about. Kept as an early exit rather than
        // deleted, because "the seam has no window at all" is worth reporting once here instead of
        // once per move further down.
        _ = seam.measuredFrame()
        guard seam.windowNumber != nil else {
            return failedOutcome(reason: "the tucked seam lost its window while being parked",
                                 from: previous, began: began, config: config)
        }
        // Hand over a CLOSURE that re-reads the seam's window, not a number. `SpacerItem`
        // resolves its own window afresh, so neither a reposition nor a Control Center recreation
        // can strand an arrange half way through.
        //
        // MEASURE before reading `windowNumber`, exactly as `seamWindowNumbers()` and
        // `tuckedSeamWindow()` already do. A bare property read only reports whatever
        // `measuredFrame()` last resolved, which is nil until the window server has been asked
        // at least once; skipping the measurement here left the very first move of an arrange
        // reading nil for a seam that plainly existed, and the failure only reproduced at
        // launch, when this closure's first call could land before anything else in this file
        // had triggered a measurement.
        let outcome = BarArranger.arrange(config: config) { [weak seam] in
            _ = seam?.measuredFrame()
            return seam?.windowNumber
        }

        // RECORD IT. The live app has no other voice, and every wiring bug in this change was
        // invisible because the only evidence came from a terminal-launched diagnostic, which
        // inherits the terminal's Accessibility grant and therefore succeeds in conditions the
        // app itself may not share.
        BarArranger.log(outcome, context: "arrange from=\(previous)")

        // FAIL VISIBLE. A failed or unverifiable transaction has already attempted rollback,
        // but the only end state that never strands an app is a resting boundary.
        guard outcome.isClean else {
            showEverything()
            return outcome
        }

        // END IN A STATE THAT HONOURS THE ZONES, which is not the same as restoring `previous`.
        //
        // Restoring it verbatim was a real bug and it shipped for one build: at launch
        // `presentation` is `.everything` by default, so the restore did nothing, the seam never
        // expanded, and a relaunch left every tucked app sitting in plain sight on the correct
        // side of a seam that was not pushing. The apps were arranged and nothing was hidden.
        //
        // A reveal is the one state worth preserving, because the user asked to see the tucked
        // run and an arrange is not a reason to take it away. Otherwise the zones decide: hide
        // if anything is meant to be hidden, and show everything if nothing is.
        switch previous {
        case .revealed: reveal()
        case .tidy, .everything: config.hidesAnything ? hide() : showEverything()
        }
        return outcome
    }

    /// A failed arrange that is still LOGGED, and that leaves the bar in a state matching what it
    /// actually did, which is nothing.
    ///
    /// Exists because an early exit from `arrangeByMovingItems` did neither. It returned an outcome
    /// describing the failure and then dropped it: the launch caller discards the return value, so
    /// the failure reached no log and no UI. It also skipped the presentation restore, leaving the
    /// bar in the fully-shown state the arrange sets up as scaffolding, so a user saw every tucked
    /// app in plain sight with nothing to explain it.
    ///
    /// The end state depends on `previous`, and collapsing the two cases was wrong in both
    /// directions in turn.
    ///
    /// The FIRST version hid whenever the zones asked for it. On a first arrange nothing has been
    /// moved, the seam is parked at the far left, so expanding it pushes nothing: the bar looks
    /// identical while `presentation` claims `.tidy`. That lie is user-visible, because `toggle()`
    /// reads `presentation`, so the next press calls `reveal()` on a rested seam and appears to do
    /// nothing.
    ///
    /// The SECOND version always showed everything, which fixed that and broke the repeat case. Item
    /// positions persist across arranges, so if a previous arrange succeeded the tucked apps are
    /// already left of the seam and resting it returns every one of them to the bar. A user with a
    /// tidy bar pressing Apply, hitting the transient seam-window failure, would watch everything
    /// they had tucked reappear with only a log line to explain it.
    ///
    /// So `previous` decides, and it is the evidence: `.tidy` means a prior arrange placed the items,
    /// so hiding pushes something real and tells the truth. `.everything`, which is the launch
    /// default, means it did not, so showing everything is the only honest end state. `.revealed` is
    /// restored either way, since the user asked to see the tucked run and a failure is not a reason
    /// to take it away.
    ///
    /// `cost` is set, because the log's `cost=` field is read as time spent and a failed arrange has
    /// usually spent seconds: about 7.5s worst case before the second guard is reached, since the
    /// parking reposition contributes a second `awaitMeasuredWidth` of its own. That reposition is
    /// exactly what guard 2 reports failing, so its wait is the one this figure must not omit.
    /// The first version left it at zero, which made an expensive failure indistinguishable from an
    /// instant one in the only channel the launch caller has.
    private func failedOutcome(reason: String,
                               from previous: Presentation,
                               began: Date,
                               config: Config) -> BarArranger.Outcome {
        var outcome = BarArranger.Outcome()
        outcome.failed.append(.init(
            bundleID: nil,
            reason: reason,
            recovery: "Choose Show Everything, then try again."))
        outcome.cost = Date().timeIntervalSince(began)
        BarArranger.log(outcome, context: "arrange from=\(previous)")
        switch previous {
        case .revealed: reveal()
        case .tidy: config.hidesAnything ? tidy() : showEverything()
        case .everything: showEverything()
        }
        return outcome
    }

    /// Blocks until the number of items on the visible bar stops changing.
    ///
    /// The observable condition for "the bar has finished reflowing". Used after resting the
    /// seams, because items that were being swept return over the following moments and an
    /// arrange that runs before they arrive skips them, after which `tidy` hides them for real.
    ///
    /// Requires the count to hold steady across consecutive samples rather than merely stop
    /// growing, because items arrive in bursts with gaps between them and one stable reading is
    /// not settled.
    private func awaitBarToSettle(timeout: TimeInterval = 1.5) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var stableSamples = 0
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let count = ItemMover.barItems().count
            if count == lastCount {
                stableSamples += 1
                if stableSamples >= Self.settledSampleCount { return }
            } else {
                lastCount = count
                stableSamples = 0
            }
        }
    }

    /// How many consecutive equal readings count as settled. Three at 0.05s is 150ms of
    /// stillness, which is longer than the gaps measured between items returning.
    private static let settledSampleCount = 3

    /// - Returns: the measured x of the cut line after the move, or nil when the seam
    ///   could not be measured at all.
    @discardableResult
    func moveCut(toSitRightOf targetX: CGFloat,
                 boundary: SpacerItem.Boundary = .tucked) -> CGFloat? {
        prepare()
        guard let seam = seams[boundary] else { return nil }

        // Remember, then set aside. The seam is destroyed and recreated to change its placement,
        // and a recreated seam starts at rest, so this is restored at the end or a move made
        // while items are hidden would return them all to the bar.
        let previous = presentation

        // THE ZERO-PROBE PATH. Check where the seam ALREADY is before moving it anywhere.
        //
        // This is free. `prepareAndVerifyPlacement` has just rested both seams and measured the
        // tucked one, so its position is known and a scan costs a measured 0.039s against a
        // reposition's 0.415s mean. Every path below spends at least one reposition, and the
        // fast path spent one even when the seam was already sitting exactly where it wanted to
        // be: `reposition` destroys and recreates the item unconditionally, so asking for the
        // placement it already has still costs full price.
        //
        // It applies whenever the seam already sits right of the target, which is the case for
        // any drag that tucks an app already being swept, for the second apply in a coalesced
        // burst, and for a correction pass that finds the seam was right all along.
        //
        // Guarded on the bar being RESTED, because an expanded seam measures a left edge of
        // about -2700 on a 2560pt bar and comparing that against a target is meaningless. That
        // exact comparison is what once left a seam spanning the whole bar.
        if presentation == .everything,
           let current = seam.measuredFrame()?.minX,
           current > targetX,
           current - targetX <= Self.fastPathSlack {
            lastGoodPlacement[boundary] = seam.currentPlacement
            switch previous {
            case .tidy: tidy()
            case .revealed: reveal()
            case .everything: break
            }
            return current
        }

        // THE FAST PATH, and the reason a repeat drag does not always cost a full search.
        //
        // Consecutive applies often want the seam where it already is. A drag changes ONE app's
        // zone, so the rightmost app that must be hidden is frequently the same app, or a
        // neighbour a few points away, and the placement that satisfied the last apply still
        // satisfies this one. Trying it costs ONE reposition; a full bisection costs five, each
        // destroying and recreating a real status item and waiting on the window server at about
        // 0.45s a turn.
        //
        // "Good enough" is deliberately asymmetric. Landing right of the target is correct, and
        // landing FURTHER right than necessary only means hiding less than asked, which is
        // visible and recoverable. Outside the slack it falls through to the search.
        //
        // Using the miss to BOUND the search below was tried and reverted. It is sound in theory
        // and it broke placement in practice: `--apply` went from 0, 0, 0 unexplained mismatches
        // to 1-3 over three runs on an unchanged configuration. The window server does not place
        // a given preference reproducibly enough for one probe's landing to be trusted as a
        // bound, which is the same instability that killed the cached slot map. The bisection
        // has to see the whole range.
        // Skipped entirely when the seam already holds the remembered placement, because the
        // zero-probe check above has then already tested this exact position and rejected it.
        // Repositioning to a placement the seam already has costs a full destroy-and-recreate for
        // a guaranteed-identical answer.
        if let remembered = lastGoodPlacement[boundary],
           remembered != seam.currentPlacement,
           let landed = seam.reposition(placement: remembered,
                                        length: SpacerItem.restingLength),
           landed > targetX,
           landed - targetX <= Self.fastPathSlack {
            switch previous {
            case .tidy: tidy()
            case .revealed: reveal()
            case .everything: break
            }
            return landed
        }

        var low = Self.minimumPlacement
        var high = Self.maximumPlacement
        var bestPlacement: Int?
        var bestX: CGFloat?

        for _ in 0..<Self.maximumProbes where low <= high {
            let mid = (low + high) / 2
            guard let landedX = seam.reposition(placement: mid,
                                                length: SpacerItem.restingLength) else {
                break
            }
            if landedX > targetX {
                // Right of the target, so this slot is a candidate. Keep the LEFTMOST such
                // slot: the seam wants to sit just past the target item, not out at the far
                // edge where it would hide more than was asked.
                if bestX == nil || landedX < bestX! {
                    bestX = landedX
                    bestPlacement = mid
                }
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        // Settle on the best slot found, or fall back to the RIGHTMOST slot when no slot sits
        // right of the target.
        //
        // The fallback is the important half. With no best slot the seam would be left wherever
        // the final bisection step happened to put it, which can be far LEFT of the target:
        // measured, a seam asked to sit right of x2011 was left at x1940, so the app it was
        // meant to hide stayed on the bar and the whole apply reported a mismatch.
        let settled = bestPlacement ?? Self.minimumPlacement
        if seam.currentPlacement != settled {
            _ = seam.reposition(placement: settled, length: SpacerItem.restingLength)
        }

        // Measure BEFORE re-expanding, for the same reason the search measures at rest: an
        // expanded seam's left edge is a negative number that describes nothing.
        //
        // Awaiting rather than reading once. A recreated item does not reach
        // `CGWindowListCopyWindowInfo` at a predictable moment, so a single read after the
        // final reposition reported "unmeasured" intermittently even though the move worked.
        let landed = seam.awaitMeasuredFrame()?.minX

        // Remember it only when it actually satisfied the request, so the fast path above can
        // never be seeded with a placement that was already wrong.
        if bestPlacement != nil { lastGoodPlacement[boundary] = settled }

        // Restore whichever state was in effect, by replaying it rather than by poking the one
        // seam back: the two seams' widths are not independent, and re-deriving both from the
        // state is what keeps them consistent.
        switch previous {
        case .tidy: tidy()
        case .revealed: reveal()
        case .everything: break
        }
        return landed
    }

}
extension HideController {

    /// `Stow --cut <name>`: moves the cut so the named item falls on the hidden side,
    /// then hides and reports which items actually left the bar.
    ///
    /// This is the end-to-end test of arranging, and it exists because the Arrange
    /// pane's button cannot be clicked from a test: synthetic mouse events are ignored
    /// for menu bar interaction on this OS. Everything except the click is exercised
    /// here, and unlike a screenshot it re-runs and diffs.
    static func runCutAndExit(matching needle: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - cut")
        print(String(repeating: "=", count: 68))

        guard PressActionProbe.isTrusted else {
            print("  accessibility  : NO, so no item can be attributed to an app")
            exit(2)
        }

        let ownBundle = Bundle.main.bundleIdentifier
        let before = BarItemOwners.refreshCache()
        let wanted = needle.lowercased()
        guard let target = before.first(where: {
            $0.name.lowercased().contains(wanted) && $0.bundleID != ownBundle
        }) else {
            print("  no third-party bar item matches \"\(needle)\"")
            let names = before.filter { $0.bundleID != ownBundle }.map(\.name)
            print("  candidates: " + names.sorted().joined(separator: ", "))
            exit(1)
        }

        print("  target           : \(target.name) at x\(Int(target.axLeftEdge))")

        let hider = HideController()
        // Awaiting, not `prepare()` then measure. A seam measured in the same tick as
        // its creation is not in the window server's list yet, which reported the cut
        // as unmeasurable on a seam that existed.
        let restingCut = hider.awaitSeamPlacement()
        print("  cut before move  : \(restingCut.map { "x\(Int($0))" } ?? "unmeasured")")

        let moved = hider.moveCut(toSitRightOf: target.axLeftEdge)
        print("  cut after move   : \(moved.map { "x\(Int($0))" } ?? "unmeasured")")
        guard let moved else {
            print("  the cut could not be measured, so nothing is provable here")
            exit(1)
        }
        let rightOfTarget = moved > target.axLeftEdge
        print("  right of target  : \(rightOfTarget ? "YES" : "NO")")

        print("")
        print("  hiding...")
        hider.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let after = BarItemOwners.refreshCache()

        print("  " + pad("APP", 22) + pad("X", 8) + pad("SIDE", 12) + "RESULT")
        var wrong = 0
        for item in before.sorted(by: { $0.axLeftEdge < $1.axLeftEdge }) {
            let x = item.axLeftEdge
            let cannotAddress = VisibleRowIdentity.cannotBeAddressedIndividually(item.bundleID)
            let stillThere = after.contains { $0.pid == item.pid && $0.name == item.name }
            let actuallyHidden = !stillThere
            // Control Center's own group is expected to STAY even on the hidden side.
            // Measured twice: the Control Center item at x1804 was left of the cut both
            // times and stayed on the bar both times. Counting that as a mismatch reported
            // a failure on the one behaviour that is not Stow's to change. This is NOT true
            // of Apple items generally: a live test moved the Apple-owned Kerberos extra
            // with the same mechanism `--cut` uses, x1153 to x1228, so an Apple item that
            // can be addressed on its own is held to the same expectation as any other.
            let expectedHidden = !cannotAddress && x <= moved
            if expectedHidden != actuallyHidden { wrong += 1 }

            let side: String
            if cannotAddress {
                side = "system"
            } else if expectedHidden {
                side = "hides"
            } else {
                side = "stays"
            }
            let result = actuallyHidden ? "gone" : "on bar"
            let flag = expectedHidden == actuallyHidden ? "" : "   <- MISMATCH"
            print("  " + pad(item.name, 22) + pad("x\(Int(x))", 8)
                  + pad(side, 12) + result + flag)
        }
        print("")
        print("  items on the wrong side of the cut: \(wrong)")

        hider.reveal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        print("  revealed, bar restored")
        exit(wrong == 0 ? 0 : 1)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
}

extension HideController {

    /// `Stow --apply`: runs the Arrange pane's own path from persisted state.
    ///
    /// Reads the saved per-app zones and the remembered home positions, plans, moves the
    /// cut, hides, and reports what actually happened. Exactly what the pane's button
    /// does, minus the click, which cannot be synthesised: mouse events are ignored for
    /// menu bar interaction on this OS.
    ///
    /// Its value is the ROUND TRIP. Unchecking an app is only useful if re-checking it
    /// brings the app back, and that was impossible in an earlier build where a hidden app
    /// dropped out of the list entirely and took its own checkbox with it.
    static func runApplyAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - apply")
        print(String(repeating: "=", count: 68))

        guard PressActionProbe.isTrusted else {
            print("  accessibility  : NO, so no item can be attributed to an app")
            exit(2)
        }

        // REFUSE to measure without a bundle identifier, rather than measuring the wrong thing.
        //
        // Every filter that keeps Stow from acting on ITSELF compares against
        // `Bundle.main.bundleIdentifier`, and that is nil when the binary runs outside its
        // `.app`. So `.build/release/Stow --apply` counted Stow's own seam as a movable app:
        // eight candidates where the installed bundle reports seven, a different
        // `tuckedBoundaryX`, and therefore a different mismatch count. Measurements taken that
        // way were quietly describing a bar Stow does not actually manage, and were compared
        // against ones taken through the bundle as though the two were the same experiment.
        guard Bundle.main.bundleIdentifier != nil else {
            print("  FATAL: no bundle identifier, so Stow cannot tell its own items apart from")
            print("  the apps it manages, and every number below would be measured against a")
            print("  bar containing Stow's own seam as though it were a third-party app.")
            print("")
            print("  Run the INSTALLED bundle instead:")
            print("    /Applications/Stow.app/Contents/MacOS/Stow --apply")
            exit(2)
        }

        let ownBundle = Bundle.main.bundleIdentifier
        let store = Store()
        let claims = BarItemOwners.refreshCache()

        // Record homes from the live bar first, so an app that is currently visible has an
        // up-to-date position and one that is hidden keeps the position it had when it was
        // last seen.
        BarHomes.record(claims.filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID) && $0.bundleID != ownBundle
        })

        // Fresh, uncached: a diagnostic that reports "0 candidates" should never be able to
        // blame a stale identity cache for it.
        let candidates = HideController.candidates(identities: BarItemOwners.identities(),
                                                   liveClaims: claims,
                                                   homes: BarHomes.all,
                                                   ownBundle: ownBundle)

        guard !candidates.isEmpty else {
            print("  Stow has never seen a third-party bar item, so there is nothing to plan")
            exit(1)
        }

        // Measure the placement floor once. It bounds what the seams can express: two apps
        // both sitting left of it cannot be separated into different zones, however they are
        // set, because no seam can be placed between them.
        // Rest the seams and measure the floor through the shipped path, so the number the
        // diagnostic prints is the one the app itself would use.
        let prober = HideController()
        prober.prepareAndVerifyPlacement()
        let floor = prober.placementFloor
        let zones: (String) -> Zone = { store.config.zone(forBundleID: $0) }
        let outcome = BarPlan.outcome(candidates: candidates, zones: zones,
                                      placementFloor: floor)
        let byZone = Dictionary(grouping: candidates) { zones($0.bundleID) }

        print("  placement floor  : " + (floor.map { "x\(Int($0))" } ?? "unmeasured"))
        if floor == nil {
            print("    The floor could not be measured from here, which is expected while")
            print("    Stow itself is running: this process creates its own seams, and the")
            print("    live app's expanded seam pushes the probe off the bar. The app")
            print("    measures it at launch, with both of its own seams at rest.")
        }

        // NAME THE BAR THIS RUN MEASURED, because a mismatch count means nothing without it.
        //
        // Two readings of this diagnostic are only comparable when the display and the app
        // positions match. That is not a nicety: mismatch counts were compared across a session
        // during which the main display changed from a 2560pt external to the 1728pt built-in,
        // and a change in the count was attributed to code that had not changed. Whether an app
        // survives depends on how its position falls between the reachable slots, so the same
        // code honestly reports a different number on a different bar.
        if let screen = NSScreen.main {
            print("  display          : \(screen.localizedName)"
                  + "  \(Int(screen.frame.width))pt wide")
        }
        print("  app positions    : "
              + candidates.sorted { $0.homeX > $1.homeX }
                  .map { "\($0.bundleID.split(separator: ".").last ?? "?")@\(Int($0.homeX))" }
                  .joined(separator: " "))
        print("    A seam can only land on a reachable slot, and `--slots` measures those. When")
        print("    the nearest slot right of the target sits past a PINNED app, that app is swept")
        print("    and reported below as a mismatch. That is the macOS placement limit showing")
        print("    through, not a defect: measured here, aiming at x1147 landed at x1217 because")
        print("    no slot exists between them, and com.example.vendoragent at x1181 was in the gap.")

        print("  apps Stow knows  : \(candidates.count)")
        print("  on bar / in Stow : \(byZone[.pinned]?.count ?? 0)"
              + " / \(byZone[.tucked]?.count ?? 0)")
        print("  boundary target  : "
              + (outcome.tuckedBoundaryX.map { "x\(Int($0))" } ?? "none"))
        if !outcome.collateral.isEmpty {
            print("  collateral       : \(outcome.collateral.joined(separator: ", "))")
        }
        if !outcome.belowPlacementFloor.isEmpty {
            print("  below the floor  : "
                  + outcome.belowPlacementFloor.joined(separator: ", "))
            print("    No seam can be placed left of the floor, so these cannot be split")
            print("    into different zones from each other. Command-drag one right of the")
            print("    seam in the menu bar to zone it separately.")
        }

        // Run the SHIPPED path, not a re-implementation of it. A diagnostic that places the
        // seams itself proves only that the diagnostic works: this one has to fail when the
        // app would fail.
        let hider = prober
        print("")
        print("  WHERE THE TIME GOES")
        hider.timingSink = { print($0) }
        let landed = hider.applyPersistedPlan(from: store.config)
        hider.timingSink = nil
        print("")
        // A SECOND apply, which is what every drag after the first actually costs.
        //
        // This is the number that matters for the reported symptom. The first apply pays for a
        // cold slot map; if the map survives, the second is much cheaper, and if it does not,
        // every drag pays the full price and the cache is buying nothing.
        print("  WHERE THE TIME GOES, SECOND APPLY (what a repeat drag costs)")
        hider.timingSink = { print($0) }
        _ = hider.applyPersistedPlan(from: store.config)
        hider.timingSink = nil
        print("")
        print("  tuck seam landed : \(landed.map { "x\(Int($0))" } ?? "unmeasured")")
        print("  state now        : \(hider.presentation)")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        // TIDY state first: pinned only.
        var wrong = 0
        let tidyOnBar = Set(BarItemOwners.refreshCache().map(\.bundleID))
        print("")
        print("  TIDY (pinned only)")
        print("  " + pad("APP", 34) + pad("ZONE", 10) + "ACTUAL")
        for candidate in candidates {
            let zone = zones(candidate.bundleID)
            let isVisible = tidyOnBar.contains(candidate.bundleID)
            // A collateral app was warned about, so it is not a failure: the pane told the
            // user it would be hidden despite being pinned.
            let excused = outcome.collateral.contains(candidate.bundleID)
            let wantedVisible = zone == .pinned && !excused
            if wantedVisible != isVisible { wrong += 1 }
            let flag = wantedVisible == isVisible
                ? (excused ? "   (warned: collateral)" : "")
                : "   <- MISMATCH"
            print("  " + pad(candidate.bundleID, 34) + pad(zone.rawValue, 10)
                  + (isVisible ? "on bar" : "off bar") + flag)
        }

        // REVEALED state: every configured app is back on the bar.
        hider.reveal()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let revealedOnBar = Set(BarItemOwners.refreshCache().map(\.bundleID))
        print("")
        print("  REVEALED (pinned + tucked)")
        print("  " + pad("APP", 34) + pad("ZONE", 10) + "ACTUAL")
        for candidate in candidates {
            let zone = zones(candidate.bundleID)
            let isVisible = revealedOnBar.contains(candidate.bundleID)
            let wantedVisible = true
            if wantedVisible != isVisible { wrong += 1 }
            let flag = wantedVisible == isVisible ? "" : "   <- MISMATCH"
            print("  " + pad(candidate.bundleID, 34) + pad(zone.rawValue, 10)
                  + (isVisible ? "on bar" : "off bar") + flag)
        }

        hider.showEverything()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        print("")
        print("  unexplained mismatches: \(wrong)")
        print("  bar restored")
        exit(wrong == 0 ? 0 : 1)
    }
}

extension HideController {

    /// `Stow --drag`: times what the Arrange board actually costs, end to end.
    ///
    /// `--apply` was not this. It measures `applyPersistedPlan` alone, from a fresh process
    /// whose bar starts fully visible, and it never pays for the owner walk the pane runs
    /// afterwards. So it reported 3.4s while a real drag was reported taking about 15s, and the
    /// gap was not noise: it was two costs the harness could not see.
    ///
    /// This reproduces the real sequence instead. Reach the hidden state first, as the app is
    /// when the user opens Arrange. Then flip one app's zone, exactly as a drop does, and pay
    /// for everything a drop pays for: the apply AND the owner walk the pane needs to redraw.
    static func runDragAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - drag")
        print(String(repeating: "=", count: 68))

        guard PressActionProbe.isTrusted else {
            print("  accessibility  : NO, so nothing here can be measured")
            exit(2)
        }

        // Same refusal as `--apply`, same reason: without a bundle identifier Stow cannot tell
        // its own seam from a managed app, so the timings would describe the wrong bar.
        guard Bundle.main.bundleIdentifier != nil else {
            print("  FATAL: no bundle identifier. Run the installed bundle instead:")
            print("    /Applications/Stow.app/Contents/MacOS/Stow --drag")
            exit(2)
        }

        // Read the real configuration, then work on a COPY and never write one back.
        //
        // `Store.config` saves on a 400ms debounce, so a diagnostic that set a zone and then
        // exited raced its own save: sometimes the write landed, sometimes the restore did, and
        // once it left `com.example.vendoragent` tucked in the real config. The next `--apply` then
        // reported three mismatches that looked like a code regression and were not. A
        // diagnostic must not be able to do that, so this one holds a value type and the Store
        // is never mutated.
        var config = Store().config
        let hider = HideController()

        // Get into the state a user is actually in: something hidden, seams expanded.
        print("")
        print("  reaching the hidden state first, as the app is when Arrange opens...")
        hider.applyPersistedPlan(from: config)
        print("  state now        : \(hider.presentation)")

        // Pick a victim to move, preferring one currently pinned so the drag has real work.
        let ownBundle = Bundle.main.bundleIdentifier
        let onBar = BarItemOwners.refreshCache().filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID) && $0.bundleID != ownBundle
        }
        guard let victim = onBar.max(by: { $0.axLeftEdge < $1.axLeftEdge }) else {
            print("  no third-party item on the bar, so there is no drag to time")
            exit(1)
        }

        let original = config.zone(forBundleID: victim.bundleID)
        let target: Zone = original == .tucked ? .pinned : .tucked
        print("")
        print("  dragging \(victim.bundleID): \(original.rawValue) -> \(target.rawValue)")
        print("  (in memory only; the saved configuration is not touched)")

        func timeOneDrop(_ zone: Zone) {
            config.setZone(zone, forBundleID: victim.bundleID)
            let began = Date()
            hider.timingSink = { print($0) }
            hider.applyPersistedPlan(from: config)
            hider.timingSink = nil
            let applyDone = Date()

            // The pane's own redraw, which every drop pays for and `--apply` never measured.
            // Reusing the apply's walk is the whole point, so this reports what the shipped
            // path costs rather than what a fresh walk would.
            let walkCost: TimeInterval
            if BarItemOwners.lastKnownClaims.isEmpty {
                let walkBegan = Date()
                _ = BarItemOwners.claims()
                walkCost = Date().timeIntervalSince(walkBegan)
            } else {
                walkCost = 0
            }
            print("  pane redraw walk       : \(String(format: "%.2f", walkCost))s"
                   + (walkCost == 0 ? "  (reused the apply's walk)" : ""))
            print("  DROP TOTAL: \(String(format: "%.2f", Date().timeIntervalSince(began)))s"
                   + "  (apply \(String(format: "%.2f", applyDone.timeIntervalSince(began)))s)")
        }

        print("")
        print("  FIRST DROP")
        timeOneDrop(target)

        print("")
        print("  SECOND DROP (dragging it back, which is what a burst of drags looks like)")
        timeOneDrop(original)

        print("")
        print("  THIRD DROP")
        timeOneDrop(target)

        // Put the BAR back the way the saved configuration says it should be. The copy above
        // diverged from it, and leaving the bar matching a configuration that was never saved
        // would be its own kind of lie.
        hider.applyPersistedPlan(from: Store().config)
        print("")
        print("  bar restored to the saved configuration; nothing was written")
        exit(0)
    }
}
