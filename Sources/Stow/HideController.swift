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

    @Published private(set) var presentation: Presentation = .everything
    @Published private(set) var lastArrangeFailures: [BarArranger.Outcome.Failure] = []

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

    func currentCandidates() -> [ManagedAppCandidate] {
        Self.candidates(identities: BarItemOwners.cachedIdentitiesList(),
                        liveClaims: BarItemOwners.lastKnownClaims,
                        homes: BarHomes.all,
                        ownBundle: Bundle.main.bundleIdentifier)
    }

    /// Merges live locations, remembered locations, and pushed-off identities.
    ///
    /// Positions are used only to keep the board in familiar bar order. The arranger
    /// acts on live window identifiers and does not place the boundary at these points.
    nonisolated static func candidates(identities: [BarItemOwners.Owner],
                                       liveClaims: [BarItemOwners.Owner],
                                       homes: [String: CGFloat],
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
        return result.sorted { $0.homeX > $1.homeX }
    }

    func hiddenApps(from config: Config) -> [HiddenApp] {
        currentCandidates().compactMap { candidate in
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
        seams[boundary]?.measuredFrame()?.width
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

    /// Applies the user's zones as one verified, all-or-nothing app transaction.
    @discardableResult
    func arrangeByMovingItems(from config: Config) -> BarArranger.Outcome {
        let began = Date()
        prepare()
        let previous = presentation

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

        let outcome = BarArranger.arrange(config: config) { [weak seam] in
            _ = seam?.measuredFrame()
            return seam?.windowNumber
        }
        BarArranger.log(outcome, context: "arrange from=\(previous)")
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
