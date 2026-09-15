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

    /// A caller may synthesize a Command-drag only after the user explicitly approves
    /// an assisted arrangement in the Arrange pane. A click that merely changes a saved
    /// profile or a lifecycle repair never grants that authority.
    enum ArrangementIntent: Sendable {
        case assistedUserAction
        case manualUserAction
        case savedLayoutRepair
        case background

        nonisolated var allowsPointerControl: Bool {
            self == .assistedUserAction
        }
    }

    @Published private(set) var presentation: Presentation = .everything
    @Published private(set) var lastArrangeFailures: [BarArranger.Outcome.Failure] = []
    @Published private(set) var candidateRevision = 0

    /// Whether a saved tucked assignment has a real status item right now.
    ///
    /// Persisted intent and live menu-bar state are deliberately separate. A running app can
    /// retain an `AXExtrasMenuBar` child at the `x = -1` sentinel, or publish no child at all,
    /// while its saved assignment remains useful for the next time the item returns. Neither
    /// condition means Stow is currently hiding an app or needs to consume a boundary slot.
    enum LiveTuckedAvailability: Equatable {
        case available(Set<String>)
        case noneAvailable
        case unknown

        var bundleIDs: Set<String> {
            if case .available(let bundleIDs) = self { return bundleIDs }
            return []
        }
    }

    var isHidden: Bool { presentation != .everything }

    private static let parkedPlacement = 900
    private static let restingWidthCeiling: CGFloat = 100
    private static let pushWidth: CGFloat = 10_000
    private var seams: [SpacerItem.Boundary: SpacerItem] = [:]
    private var restingCutX: CGFloat?
    /// Last conclusively observed live tucked apps. Unknown refreshes preserve the previous
    /// answer rather than laundering missing Accessibility evidence into a confident zero.
    private var activeTuckedBundleIDs: Set<String> = []

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
        seams[.tucked]?.expand(toPush: SpacerItem.restingLength)
        presentation = .everything
    }

    /// Removes an idle boundary entirely so saved-but-unavailable apps do not consume 17pt.
    ///
    /// The placement preference remains intact. If one of those apps later republishes a real
    /// status item, lifecycle reconciliation recreates the same boundary and applies the saved
    /// assignment. This is used only after a conclusive live scan reports zero tucked items.
    private func deactivateBoundary() {
        RevealCoordinator.shared.cancelPendingRetucks()
        for seam in seams.values {
            seam.expand(toPush: SpacerItem.restingLength)
            seam.remove()
        }
        seams.removeAll()
        restingCutX = nil
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
    @discardableResult
    func refreshCandidatesWithoutMoving(from config: Config) -> LiveTuckedAvailability {
        let refreshed = BarItemOwners.refreshCaches()
        let availability = Self.liveTuckedAvailability(
            config: config,
            identities: refreshed.identities,
            windows: ItemMover.positionableItems(),
            accessibilityTrusted: PressActionProbe.isTrusted,
            ownBundle: Bundle.main.bundleIdentifier)
        switch availability {
        case .available(let bundleIDs):
            activeTuckedBundleIDs = bundleIDs
        case .noneAvailable:
            activeTuckedBundleIDs = []
        case .unknown:
            break
        }
        candidateRevision &+= 1
        BarArranger.append("candidate refresh identities=\(refreshed.identities.count)"
                           + " claims=\(refreshed.claims.count) pointerMoves=0")
        return availability
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

    /// Resolves persisted tucked assignments against status items that physically exist now.
    ///
    /// A positive AX x is a visible item. A value below -1 is a genuinely pushed item only when
    /// WindowServer still publishes a matching non-zero-width window. Exactly -1 is macOS's
    /// "no usable position" sentinel and must never activate Stow's boundary by itself.
    nonisolated static func liveTuckedAvailability(
        config: Config,
        identities: [BarItemOwners.Owner],
        windows: [ObservedItem],
        accessibilityTrusted: Bool,
        ownBundle: String?
    ) -> LiveTuckedAvailability {
        guard config.hidesAnything else { return .noneAvailable }

        let live = Set(identities.compactMap { owner -> String? in
            guard !owner.bundleID.isEmpty,
                  owner.bundleID != ownBundle,
                  !VisibleRowIdentity.cannotBeAddressedIndividually(owner.bundleID),
                  config.zone(forBundleID: owner.bundleID) == .tucked else { return nil }

            if owner.axLeftEdge > 0 { return owner.bundleID }
            guard BarItemOwners.isPushedOffScreen(owner.axLeftEdge) else { return nil }
            let hasWindow = windows.contains {
                $0.frame.width > 0 && abs($0.frame.minX - owner.axLeftEdge) <= 10
            }
            return hasWindow ? owner.bundleID : nil
        })

        if !live.isEmpty { return .available(live) }
        // No Accessibility grant, or an entirely empty owner walk, is missing evidence. It is
        // not proof that every configured item is absent.
        guard accessibilityTrusted, !identities.isEmpty else { return .unknown }
        return .noneAvailable
    }

    func hiddenApps(from config: Config) -> [HiddenApp] {
        activeTuckedBundleIDs.compactMap { bundleID in
            guard config.zone(forBundleID: bundleID) == .tucked,
                  let running = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID).first
            else { return nil }
            return HiddenApp(bundleID: bundleID,
                             name: running.localizedName ?? bundleID,
                             icon: running.icon,
                             zone: .tucked,
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
        return seams[boundary]?.measuredFrame()?.width
    }

    func seamWindowNumbers() -> Set<CGWindowID> {
        guard let seam = seams[.tucked] else { return [] }
        _ = seam.measuredFrame()
        if let window = seam.windowNumber { return [window] }
        return []
    }

    func tuckedSeamWindow() -> CGWindowID? {
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
        guard config.hidesAnything else {
            activeTuckedBundleIDs = []
            deactivateBoundary()
            BarArranger.append("launch restore=everything pointerMoves=0")
            return
        }

        awaitBarToSettle(timeout: Self.safeRestoreSettleTimeout)
        switch refreshCandidatesWithoutMoving(from: config) {
        case .noneAvailable:
            deactivateBoundary()
            BarArranger.append("launch restore=inactive liveTucked=0 pointerMoves=0")
            return
        case .unknown:
            let outcome = failedOutcome(
                reason: PressActionProbe.isTrusted
                    ? "menu-bar item identity is not available yet"
                    : "Accessibility access is off, so apps cannot be identified safely",
                began: Date())
            BarArranger.log(outcome, context: "launch restore evidence")
            return
        case .available:
            prepare()
            showEverything()
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
            activeTuckedBundleIDs = []
            deactivateBoundary()
            return
        }

        awaitBarToSettle(timeout: Self.safeRestoreSettleTimeout)
        switch refreshCandidatesWithoutMoving(from: config) {
        case .noneAvailable:
            lastArrangeFailures = []
            deactivateBoundary()
            BarArranger.append("lifecycle reconcile=inactive liveTucked=0 pointerMoves=0")
            return
        case .unknown:
            _ = failedOutcome(
                reason: PressActionProbe.isTrusted
                    ? "menu-bar item identity is not available yet"
                    : "Accessibility access is off, so apps cannot be identified safely",
                began: Date())
            return
        case .available:
            break
        }

        if seams[.tucked] == nil {
            prepare()
            showEverything()
            awaitBarToSettle(timeout: Self.safeRestoreSettleTimeout)
            _ = BarItemOwners.refreshCache()
        }
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
        if !config.hidesAnything {
            activeTuckedBundleIDs = []
            lastArrangeFailures = []
            deactivateBoundary()
            var outcome = BarArranger.Outcome()
            outcome.cost = Date().timeIntervalSince(began)
            BarArranger.log(outcome, context: "arrange no tucked assignments pointerMoves=0")
            return outcome
        }

        switch refreshCandidatesWithoutMoving(from: config) {
        case .noneAvailable:
            lastArrangeFailures = []
            deactivateBoundary()
            var outcome = BarArranger.Outcome()
            outcome.cost = Date().timeIntervalSince(began)
            BarArranger.log(outcome, context: "arrange inactive liveTucked=0 pointerMoves=0")
            return outcome
        case .unknown:
            return failedOutcome(
                reason: PressActionProbe.isTrusted
                    ? "menu-bar item identity is not available yet"
                    : "Accessibility access is off, so apps cannot be identified safely",
                began: began)
        case .available:
            break
        }

        guard intent.allowsPointerControl else {
            var outcome = BarArranger.Outcome()
            outcome.failed = [.init(
                bundleID: nil,
                reason: "this layout needs menu-bar movement, but assisted arrangement is off.",
                recovery: "Command-drag the selected icons yourself, or choose Assist Arrange in Arrange." )]
            outcome.cost = Date().timeIntervalSince(began)
            lastArrangeFailures = outcome.failed
            BarArranger.log(outcome, context: "arrange blocked unapproved pointerMoves=0")
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
            activeTuckedBundleIDs.isEmpty ? deactivateBoundary() : hide()
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
