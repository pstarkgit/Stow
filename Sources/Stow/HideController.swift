import AppKit
import Combine
import SwiftUI

/// Owns Stow's single stationary boundary and the visible/hidden presentation.
///
/// The boundary is a status item Stow owns. Widening it pushes everything to its LEFT off the
/// bar; that is the whole hiding mechanism, and it is the only thing Stow ever moves. Which apps
/// sit left of the boundary is decided by the user with a real Command-drag in the real menu bar,
/// and remembered by macOS itself across relaunches. Stow never synthesises a drag.
@MainActor
final class HideController: ObservableObject {
    enum Presentation: Equatable, Sendable {
        case tidy
        case revealed
        case everything
    }

    /// Something about the bar the user should hear about, because Stow will not act on it.
    struct LayoutNotice: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// An app the user stowed is sitting on the visible side again.
            case backOnBar
            /// An app the user kept on the bar has ended up left of the boundary.
            case slippedIntoStow
            /// An app Stow has never seen a decision for appeared on the visible side.
            case newApp
        }
        let bundleID: String
        let kind: Kind
        var id: String { bundleID }
    }

    /// One app in real bar order, with the side of the boundary it is on right now.
    struct LiveEntry: Equatable, Sendable {
        let bundleID: String
        let name: String
        let pid: pid_t
        /// The item's left edge in AX coordinates: negative when pushed off.
        let x: CGFloat
        let isHidden: Bool
    }

    @Published private(set) var presentation: Presentation = .everything
    @Published private(set) var notices: [LayoutNotice] = []
    @Published private(set) var candidateRevision = 0
    /// Apps left of the boundary, in bar order left to right. Truth from the bar, never config.
    @Published private(set) var liveEntries: [LiveEntry] = []

    /// Points of free space left of the leftmost item, supplied by whoever owns the budget.
    /// Used only to size a partial hide; nil falls back to hiding the whole run.
    var headroomProvider: (() -> CGFloat?)?

    var isHidden: Bool { presentation != .everything }
    var hiddenBundleIDs: [String] { liveEntries.filter(\.isHidden).map(\.bundleID) }
    var visibleBundleIDs: [String] { liveEntries.filter { !$0.isHidden }.map(\.bundleID) }

    private static let parkedPlacement = 900
    private static let pushWidthAll: CGFloat = 10_000
    private var seams: [SpacerItem.Boundary: SpacerItem] = [:]
    private var restingCutX: CGFloat?
    private var dismissedNotices: Set<String> = []

    static func placeOwnTokenOutsideSeam() {
        UserDefaults.standard.set(tokenOffsetFromRightEdge,
                                  forKey: "NSStatusItem Preferred Position Item-0")
    }

    nonisolated static let tokenOffsetFromRightEdge = 2

    // MARK: - The boundary

    func prepare() {
        for boundary in SpacerItem.Boundary.allCases where seams[boundary] == nil {
            SpacerItem.place(boundary, offsetFromRightEdge: Self.parkedPlacement)
            seams[boundary] = SpacerItem(boundary: boundary, state: .tidy)
        }
    }

    func tidy() {
        prepare()
        seams[.tucked]?.expand(toPush: Self.pushWidthAll)
        presentation = .tidy
    }

    /// Brings the whole stowed run back for a moment, without changing what is stowed.
    func reveal() {
        prepare()
        seams[.tucked]?.expand(toPush: SpacerItem.restingLength)
        presentation = .revealed
    }

    /// Shows the complete bar and invalidates every delayed re-hide from an earlier reveal.
    func showEverything() {
        RevealCoordinator.shared.cancelPendingRetucks()
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

    /// Hides the stowed run except for the `peek` items nearest the boundary.
    ///
    /// Profiles are this and nothing more: a spacer width. Zero hides everything left of the
    /// boundary, a large number shows all of it, and anything in between keeps the nearest few
    /// on the bar. No app is moved, so a profile switch cannot be refused by macOS.
    func applyProfile(peek: Int, config: Config) {
        prepare()
        if peek <= 0 {
            hide()
            return
        }
        showEverything()
        awaitBarToSettle(timeout: 0.75)
        let layout = refresh(config: config)
        let hidden = layout.filter(\.isHidden)
        guard !hidden.isEmpty else { return }
        if peek >= hidden.count {
            return
        }
        // The items to push are the ones FARTHEST from the boundary, which in bar order are the
        // leftmost. Their widths come from the window server; an item with no matching window
        // contributes nothing and the fallback below hides everything.
        let windows = BarItems.positionable()
        let toHide = hidden.prefix(hidden.count - peek)
        let widths: [CGFloat] = toHide.compactMap { entry in
            windows.first { abs($0.frame.minX - entry.x) <= 10 }?.frame.width
        }
        guard widths.count == toHide.count else {
            hide()
            return
        }
        let push = Self.pushWidth(hiding: widths, headroom: headroomProvider?() ?? 0)
        seams[.tucked]?.expand(toPush: push)
        presentation = .tidy
        keepOwnTokenReachable()
    }

    /// How wide the boundary must be to push exactly `hiding` off the bar.
    ///
    /// Everything left of the boundary shifts left by the boundary's width, and an item leaves the
    /// bar when it runs into the frontmost app's menus. So the push is the free space that has to
    /// be consumed first, plus the widths of the items that must go, plus a little slack so the
    /// last one does not sit half-clipped.
    nonisolated static func pushWidth(hiding widths: [CGFloat], headroom: CGFloat) -> CGFloat {
        guard !widths.isEmpty else { return SpacerItem.restingLength }
        return widths.reduce(0, +) + max(0, headroom) + 4
    }

    nonisolated static func ownTokenIsVisible(in identities: [BarItemOwners.Owner],
                                              ownBundle: String) -> Bool {
        identities.contains { $0.bundleID == ownBundle && $0.axLeftEdge > 0 }
    }

    /// Fails open: if hiding took Stow's own token with it, there would be no control left.
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

    // MARK: - What is on which side

    /// Re-reads the bar and recomputes which apps are stowed and what the user should hear about.
    ///
    /// Read-only. Nothing here changes the bar.
    @discardableResult
    func refresh(config: Config) -> [LiveEntry] {
        let refreshed = BarItemOwners.refreshCaches()
        let layout = Self.liveLayout(identities: refreshed.identities,
                                     windows: BarItems.positionable(),
                                     cutX: measuredCutX(),
                                     presentation: presentation,
                                     ownBundle: Bundle.main.bundleIdentifier)
        liveEntries = layout
        notices = Self.layoutNotices(config: config,
                                     hidden: layout.filter(\.isHidden).map(\.bundleID),
                                     visible: layout.filter { !$0.isHidden }.map(\.bundleID),
                                     dismissed: dismissedNotices)
        candidateRevision &+= 1
        StowLog.append("refresh identities=\(refreshed.identities.count)"
                       + " hidden=\(layout.filter(\.isHidden).count)"
                       + " notices=\(notices.count) pointerMoves=0")
        return layout
    }

    /// Every third-party app on the bar, in bar order, with the side it is on.
    ///
    /// An item is stowed when the window server has it pushed off the left edge with a real
    /// window, or, while the bar is fully shown, when it sits left of the boundary and would be
    /// pushed by the next hide. AX's `x = -1` sentinel means "no position" and is never a side.
    nonisolated static func liveLayout(identities: [BarItemOwners.Owner],
                                       windows: [ObservedItem],
                                       cutX: CGFloat?,
                                       presentation: Presentation,
                                       ownBundle: String?) -> [LiveEntry] {
        var seen: Set<String> = []
        var entries: [LiveEntry] = []
        for owner in identities {
            guard !owner.bundleID.isEmpty,
                  owner.bundleID != ownBundle,
                  !VisibleRowIdentity.cannotBeAddressedIndividually(owner.bundleID),
                  owner.axLeftEdge != -1,
                  !seen.contains(owner.bundleID) else { continue }

            let pushed = BarItemOwners.isPushedOffScreen(owner.axLeftEdge)
                && windows.contains {
                    $0.frame.width > 0 && abs($0.frame.minX - owner.axLeftEdge) <= 10
                }
            let leftOfCut: Bool = {
                guard presentation != .tidy, let cutX, owner.axLeftEdge > 0 else { return false }
                return owner.axLeftEdge < cutX
            }()
            guard pushed || owner.axLeftEdge > 0 else { continue }
            seen.insert(owner.bundleID)
            entries.append(LiveEntry(bundleID: owner.bundleID,
                                     name: owner.name,
                                     pid: owner.pid,
                                     x: owner.axLeftEdge,
                                     isHidden: pushed || leftOfCut))
        }
        return entries.sorted { $0.x < $1.x }
    }

    /// What has changed against the user's recorded decisions.
    ///
    /// Pure so the three cases are pinned by tests. A config with no decisions yet produces no
    /// new-app notices, because on a first run every app would be "new".
    nonisolated static func layoutNotices(config: Config,
                                          hidden: [String],
                                          visible: [String],
                                          dismissed: Set<String>) -> [LayoutNotice] {
        let recorded = config.zoneByBundleID ?? [:]
        var out: [LayoutNotice] = []
        for bundleID in visible where !dismissed.contains(bundleID) {
            switch recorded[bundleID] {
            case .tucked: out.append(LayoutNotice(bundleID: bundleID, kind: .backOnBar))
            case .pinned: break
            case nil where !recorded.isEmpty:
                out.append(LayoutNotice(bundleID: bundleID, kind: .newApp))
            case nil: break
            }
        }
        for bundleID in hidden where !dismissed.contains(bundleID) {
            if recorded[bundleID] == .pinned {
                out.append(LayoutNotice(bundleID: bundleID, kind: .slippedIntoStow))
            }
        }
        return out
    }

    /// The live sides as zone decisions, for the store to record while the user is arranging.
    var observedZones: [String: Zone] {
        Dictionary(uniqueKeysWithValues: liveEntries.map { ($0.bundleID, $0.isHidden ? Zone.tucked : .pinned) })
    }

    func dismissNotice(_ bundleID: String) {
        dismissedNotices.insert(bundleID)
        notices.removeAll { $0.bundleID == bundleID }
    }

    func currentCandidates(config: Config? = nil) -> [ManagedAppCandidate] {
        let configured = Set(config?.zoneByBundleID?.keys ?? [:].keys)
        return Self.candidates(identities: BarItemOwners.cachedIdentitiesList(),
                               liveClaims: BarItemOwners.lastKnownClaims,
                               homes: BarHomes.all,
                               configuredBundleIDs: configured,
                               ownBundle: Bundle.main.bundleIdentifier)
    }

    /// Merges live locations, remembered locations, and pushed-off identities into one list in
    /// familiar bar order. Used for profile seeding; positions are for ordering only.
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

    /// The apps Stow is hiding right now, in bar order, for the shelf.
    func hiddenApps(from config: Config) -> [HiddenApp] {
        liveEntries.filter(\.isHidden).compactMap { entry in
            guard let running = NSRunningApplication(processIdentifier: entry.pid)
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first
            else { return nil }
            return HiddenApp(bundleID: entry.bundleID,
                             name: running.localizedName ?? entry.name,
                             icon: running.icon,
                             zone: .tucked,
                             pid: running.processIdentifier)
        }
    }

    // MARK: - Measurements the Doctor and the panes read

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

    // MARK: - Launch and lifecycle

    /// Restores the hidden state at launch.
    ///
    /// macOS recreates the boundary where the user left it and every other item where the user
    /// left it, so the only question is whether anything sits left of the boundary. If so, hide.
    /// Nothing is moved and nothing is repaired; a stowed app that macOS put back on the visible
    /// side shows up as a notice in Arrange instead.
    func restoreSavedLayout(from config: Config) {
        prepare()
        awaitBarToSettle(timeout: Self.launchSettleTimeout)
        let layout = refresh(config: config)
        if layout.contains(where: \.isHidden) {
            hide()
            StowLog.append("launch restore=tidy hidden=\(hiddenBundleIDs.count) pointerMoves=0")
        } else {
            StowLog.append("launch restore=everything pointerMoves=0")
        }
    }

    /// Re-reads the bar after an app launched or quit. Read-only; a new icon that landed on the
    /// visible side becomes a notice, and one that landed left of a wide boundary is already
    /// hidden by macOS without Stow doing anything.
    func reconcileSavedLayoutAfterCandidateChange(from config: Config) {
        awaitBarToSettle(timeout: Self.launchSettleTimeout)
        _ = refresh(config: config)
        StowLog.append("lifecycle reconcile hidden=\(hiddenBundleIDs.count) pointerMoves=0")
    }

    private static let launchSettleTimeout: TimeInterval = 0.75

    private func awaitBarToSettle(timeout: TimeInterval = 1.5) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var stableSamples = 0
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let count = BarItems.onBar().count
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
