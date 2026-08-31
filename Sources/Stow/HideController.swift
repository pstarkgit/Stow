import AppKit
import Combine
import SwiftUI

/// Owns Stow's single stationary boundary and the visible/hidden presentation.
///
/// Apps move around this boundary. The boundary is parked once at the far-left
/// placement and never searched across the bar, which prevents collateral hiding.
@MainActor
final class HideController: ObservableObject {
    enum Presentation: Equatable, Sendable {
        case tidy
        case revealed
        case everything
    }

    /// Whether a caller is authorized to synthesize the Command-drag that reorders another app.
    enum ArrangementIntent: Sendable {
        case explicitUserAction
        case savedLayoutRepair
        case background

        nonisolated var allowsPointerControl: Bool {
            self == .explicitUserAction || self == .savedLayoutRepair
        }
    }

    @Published private(set) var presentation: Presentation = .everything
    @Published private(set) var lastArrangeFailures: [BarArranger.Outcome.Failure] = []
    @Published private(set) var candidateRevision = 0

    var isHidden: Bool { presentation != .everything }

    private static let parkedPlacement = 900
    private static let restingWidthCeiling: CGFloat = 100
    private static let pushWidth: CGFloat = 10_000
    private var seams: [SpacerItem.Boundary: SpacerItem] = [:]
    private var restingCutX: CGFloat?

    static func placeOwnTokenOutsideSeam() {
        UserDefaults.standard.set(tokenOffsetFromRightEdge,
                                  forKey: "NSStatusItem Preferred Position Item-0")
    }

    nonisolated static let tokenOffsetFromRightEdge = 2

    func prepare() {
        for boundary in SpacerItem.Boundary.allCases where seams[boundary] == nil {
            SpacerItem.place(boundary, offsetFromRightEdge: Self.parkedPlacement)
            seams[boundary] = SpacerItem(boundary: boundary, state: .tidy)
        }
    }

    func tidy() {
        prepare()
        seams[.tucked]?.expand(toPush: Self.pushWidth)
        presentation = .tidy
    }

    func reveal() {
        prepare()
        seams[.tucked]?.expand(toPush: SpacerItem.restingLength)
        presentation = .revealed
    }

    /// Shows the complete bar and invalidates every delayed move from an earlier reveal.
    func showEverything() {
        RevealCoordinator.shared.cancelPendingRetucks()
        prepare()
        seams[.tucked]?.expand(toPush: SpacerItem.restingLength)
        presentation = .everything
    }

    func toggle() {
        presentation == .tidy ? reveal() : hide()
    }

    func hide() {
        tidy()
        keepOwnTokenReachable()
    }

    nonisolated static func ownTokenIsVisible(in identities: [BarItemOwners.Owner],
                                              ownBundle: String) -> Bool {
        identities.contains { $0.bundleID == ownBundle && $0.axLeftEdge > 0 }
    }

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

    func currentCandidates(config: Config? = nil) -> [ManagedAppCandidate] {
        let configured = Set(config?.zoneByBundleID?.keys ?? [:].keys)
        return Self.candidates(identities: BarItemOwners.cachedIdentitiesList(),
                               liveClaims: BarItemOwners.lastKnownClaims,
                               homes: BarHomes.all,
                               configuredBundleIDs: configured,
                               ownBundle: Bundle.main.bundleIdentifier)
    }

    /// Refreshes app discovery and redraws observers without changing menu-bar geometry.
    ///
    /// Discovery is kept separate from reconciliation so callers can redraw observers before
    /// deciding whether the already-selected saved layout needs repair.
    func refreshCandidatesWithoutMoving() {
        let refreshed = BarItemOwners.refreshCaches()
        candidateRevision &+= 1
        BarArranger.append("candidate refresh identities=\(refreshed.identities.count)"
                           + " claims=\(refreshed.claims.count) pointerMoves=0")
    }

    /// Merges live locations, remembered locations, and pushed-off identities.
    ///
    /// Positions are used only to keep the board in familiar bar order. The arranger
    /// acts on live window identifiers and does not place the boundary at these points.
    nonisolated static func candidates(identities: [BarItemOwners.Owner],
                                       liveClaims: [BarItemOwners.Owner],
                                       homes: [String: CGFloat],
                                       configuredBundleIDs: Set<String> = [],
                                       ownBundle: String?) -> [ManagedAppCandidate] {
        var homes = homes.filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.key) && $0.key != ownBundle
        }
        for claim in liveClaims
        where !VisibleRowIdentity.cannotBeAddressedIndividually(claim.bundleID)
            && claim.bundleID != ownBundle
            && !claim.bundleID.isEmpty {
            homes[claim.bundleID] = claim.axLeftEdge
        }

        var result = homes.map {
            ManagedAppCandidate(bundleID: $0.key, homeX: $0.value, isPushable: true)
        }
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
            ManagedAppCandidate(bundleID: $0, homeX: 0, isPushable: false)
        }
        let represented = Set(result.map(\.bundleID))
        let configuredOnly = configuredBundleIDs.filter {
            !represented.contains($0)
                && $0 != ownBundle
                && !VisibleRowIdentity.cannotBeAddressedIndividually($0)
        }
        result += configuredOnly.sorted().map {
            ManagedAppCandidate(bundleID: $0, homeX: 0, isPushable: false)
        }
        return result.sorted { $0.homeX > $1.homeX }
    }

    func hiddenApps(from config: Config) -> [HiddenApp] {
        currentCandidates(config: config).compactMap { candidate in
            let zone = config.zone(forBundleID: candidate.bundleID)
            guard zone != .pinned,
                  let running = NSRunningApplication
                    .runningApplications(withBundleIdentifier: candidate.bundleID).first
            else { return nil }
            return HiddenApp(bundleID: candidate.bundleID,
                             name: running.localizedName ?? candidate.bundleID,
                             icon: running.icon,
                             zone: zone,
                             pid: running.processIdentifier)
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func measuredCutX() -> CGFloat? {
        if presentation == .tidy { return restingCutX }
        if let live = seams[.tucked]?.measuredFrame()?.minX {
            restingCutX = live
            return live
        }
        return restingCutX
    }

    func measuredSeamWidth(_ boundary: SpacerItem.Boundary = .tucked) -> CGFloat? {
        prepare()
        return seams[boundary]?.measuredFrame()?.width
    }

    func seamWindowNumbers() -> Set<CGWindowID> {
        prepare()
        guard let seam = seams[.tucked] else { return [] }
        _ = seam.measuredFrame()
        if let window = seam.windowNumber { return [window] }
        return []
    }

    func tuckedSeamWindow() -> CGWindowID? {
        prepare()
        guard let seam = seams[.tucked] else { return nil }
        _ = seam.measuredFrame()
        return seam.windowNumber
    }

    /// Restores the saved visibility state at launch.
    ///
    /// The common path remains read-only: if macOS recreated the boundary in the same place,
    /// expanding it is enough. In practice, removing Stow's status item during an update or
    /// relaunch lets Control Center collapse the tucked group, then recreates the boundary inside
    /// that group. The old policy treated that deterministic launch behavior as user drift and
    /// left every app visible forever. When the read-only proof fails, repair the saved grouping
    /// with the same bounded mover as explicit Arrange. ItemMover hides and restores the cursor,
    /// refuses real gestures/modifiers, and this path still fails open if macOS rejects a move.
    func restoreSavedLayout(from config: Config) {
        lastArrangeFailures = []
        showEverything()
        guard config.hidesAnything else {
            BarArranger.append("launch restore=everything pointerMoves=0")
            return
        }

        var attempt = 0
        let arranged = Self.executeSafeRestoreChecks(
            perform: {
                attempt += 1
                // MenuBarExtra and Control Center create their windows asynchronously at login.
                // Wait for the visible bar count to settle before comparing it with the saved
                // zones; the old immediate check permanently warned on an already-correct bar.
                awaitBarToSettle(timeout: Self.safeRestoreSettleTimeout)
                let claims = BarItemOwners.refreshCache()
                let seamID = tuckedSeamWindow()
                let matches = BarArranger.isArranged(
                    config: config,
                    seamWindow: { seamID })
                BarArranger.append("launch restore check attempt=\(attempt)"
                                   + " claims=\(claims.count)"
                                   + " seam=\(seamID.map(String.init) ?? "missing")"
                                   + " arranged=\(matches) pointerMoves=0")
                return matches
            },
            beforeRetry: {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(Self.safeRestoreRetryDelay))
            })

        guard !arranged else {
            hide()
            BarArranger.append("launch restore=tidy pointerMoves=0")
            return
        }

        BarArranger.append("launch restore repair=required")
        let outcome = arrangeByMovingItems(from: config, intent: .savedLayoutRepair)
        BarArranger.log(outcome, context: "launch restore repair")
    }

    /// Reconciles a configured app that creates or removes its menu-bar item after launch.
    ///
    /// This is intentionally narrower than a background profile change: it reapplies the layout
    /// the user already selected, and only when the live order no longer matches that layout.
    /// Unchanged lifecycle notifications stay on the read-only path and move nothing.
    func reconcileSavedLayoutAfterCandidateChange(from config: Config) {
        guard config.hidesAnything else {
            lastArrangeFailures = []
            showEverything()
            return
        }

        awaitBarToSettle(timeout: Self.safeRestoreSettleTimeout)
        _ = BarItemOwners.refreshCache()
        let seamID = tuckedSeamWindow()
        if BarArranger.isArranged(config: config, seamWindow: { seamID }) {
            lastArrangeFailures = []
            if presentation == .everything { hide() }
            BarArranger.append("lifecycle reconcile=already-correct pointerMoves=0")
            return
        }

        let outcome = arrangeByMovingItems(from: config, intent: .savedLayoutRepair)
        BarArranger.log(outcome, context: "lifecycle reconcile")
    }

    /// Retries the read-only launch proof before escalating to the bounded saved-layout repair.
    ///
    /// A transient false result is expected while Control Center is still constructing the bar.
    /// A persistent false result means the caller must reconcile the saved grouping.
    static func executeSafeRestoreChecks(
        perform: () -> Bool,
        beforeRetry: () -> Void
    ) -> Bool {
        for attempt in 1...maximumSafeRestoreAttempts {
            if perform() { return true }
            if attempt < maximumSafeRestoreAttempts { beforeRetry() }
        }
        return false
    }

    private static let maximumSafeRestoreAttempts = 2
    private static let safeRestoreSettleTimeout: TimeInterval = 0.75
    private static let safeRestoreRetryDelay: TimeInterval = 0.35

    /// Applies the user's zones through bounded, forward-only convergence passes.
    @discardableResult
    func arrangeByMovingItems(
        from config: Config,
        intent: ArrangementIntent
    ) -> BarArranger.Outcome {
        let began = Date()
        guard intent.allowsPointerControl else {
            var outcome = BarArranger.Outcome()
            outcome.failed = [.init(
                bundleID: nil,
                reason: "a background profile change needs menu-bar movement.",
                recovery: "Choose that profile manually so Stow never takes the pointer silently.")]
            outcome.cost = Date().timeIntervalSince(began)
            lastArrangeFailures = outcome.failed
            BarArranger.log(outcome, context: "arrange blocked background pointerMoves=0")
            return outcome
        }
        prepare()
        let previous = presentation

        // A warning describes the latest completed arrange, not permanent app state. Clear it
        // before beginning a fresh attempt so a prior refusal cannot remain on screen while the
        // replacement transaction is already succeeding.
        lastArrangeFailures = []

        showEverything()
        guard let seam = seams[.tucked] else {
            return failedOutcome(reason: "the Stow boundary is not available", began: began)
        }
        _ = seam.awaitMeasuredWidth { $0 < Self.restingWidthCeiling }
        awaitBarToSettle()

        if seam.currentPlacement != Self.parkedPlacement {
            _ = seam.reposition(placement: Self.parkedPlacement,
                                length: SpacerItem.restingLength)
            _ = seam.awaitMeasuredWidth { $0 < Self.restingWidthCeiling }
        }
        _ = seam.measuredFrame()
        guard seam.windowNumber != nil else {
            return failedOutcome(reason: "the Stow boundary lost its window", began: began)
        }

        var attempt = 0
        var outcome = Self.executeArrangementWithTransientRetry(
            perform: {
                attempt += 1
                let result = BarArranger.arrange(config: config) { [weak seam] in
                    _ = seam?.measuredFrame()
                    return seam?.windowNumber
                }
                BarArranger.log(result, context: "arrange from=\(previous) attempt=\(attempt)")
                return result
            },
            beforeRetry: {
                // The move primitive is healthy, but Control Center intermittently refuses one
                // whole app transaction. A fresh scan immediately succeeds in that condition.
                // Collapse the boundary and let the bar settle before resolving every live window
                // and owner again; never reuse the failed transaction's geometry.
                showEverything()
                _ = seam.awaitMeasuredWidth { $0 < Self.restingWidthCeiling }
                awaitBarToSettle()
            })
        outcome.cost = Date().timeIntervalSince(began)
        lastArrangeFailures = outcome.failed

        guard outcome.isClean else {
            showEverything()
            return outcome
        }

        switch previous {
        case .revealed:
            reveal()
        case .tidy, .everything:
            config.hidesAnything ? hide() : showEverything()
        }
        return outcome
    }

    /// Runs up to two fresh passes after app-specific refusals.
    ///
    /// Failures without an app identity are environmental or structural (Accessibility, owner
    /// resolution, or the boundary itself). Repeating those cannot help and would only freeze the
    /// panel for another full arrange budget. Named app failures are transient and can also move
    /// between apps as a pass makes progress. Three total passes bound the pointer work while
    /// allowing the fresh scan to operate only on what the preceding pass left unresolved.
    static func executeArrangementWithTransientRetry(
        perform: () -> BarArranger.Outcome,
        beforeRetry: () -> Void
    ) -> BarArranger.Outcome {
        var outcome = perform()
        var attempt = 1
        while attempt < maximumArrangementAttempts,
              shouldRetryArrangement(outcome) {
            beforeRetry()
            outcome = perform()
            attempt += 1
        }
        return outcome
    }

    nonisolated static func shouldRetryArrangement(_ outcome: BarArranger.Outcome) -> Bool {
        !outcome.failed.isEmpty && outcome.failed.allSatisfy { $0.bundleID != nil }
    }

    nonisolated private static let maximumArrangementAttempts = 3

    private func failedOutcome(reason: String,
                               began: Date) -> BarArranger.Outcome {
        var outcome = BarArranger.Outcome()
        outcome.failed.append(.init(
            bundleID: nil,
            reason: reason,
            recovery: "Choose Show Everything, then try again."))
        outcome.cost = Date().timeIntervalSince(began)
        lastArrangeFailures = outcome.failed
        BarArranger.log(outcome, context: "arrange")
        showEverything()
        return outcome
    }

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

    private static let settledSampleCount = 3
}
