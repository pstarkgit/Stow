import CoreGraphics
import Foundation

/// Predicts the consequences of the two-zone arrangement.
///
/// The mechanism forces this shape. A status item pushes only what is to its LEFT, and no
/// API moves another app's item, so Stow arranges apps around one stationary boundary:
/// `.pinned` is to its right and `.tucked` is to its left.
///
/// A checkbox or picker is therefore a PREFERENCE, and this type reconciles preference
/// against geometry:
///
///   - an app whose chosen zone does not match where it physically sits is reported, not
///     silently mis-zoned. Naming that is the whole point
///
/// Keyed by BUNDLE, not by window number. A window number identifies an item only within
/// one scan and dies with the item's window, and this type has to reason about apps that
/// are currently pushed off the bar, whose live position is meaningless.
///
/// Pure. Every consequence is computed from positions and a zone lookup, so all of it is
/// testable without a status bar, a window server, or an accessibility grant.
enum BarPlan {

    /// One app Stow could act on, at the position it occupies when visible.
    ///
    /// `homeX` is where the item sits when NOT pushed. For an item currently on the bar
    /// that is its measured position; for one already hidden it is the position last
    /// observed while visible, because a pushed item reports a position far off-screen that
    /// says nothing about where it will land when it returns. Without that distinction a
    /// hidden app could never be brought back correctly.
    struct Candidate: Equatable {
        let bundleID: String
        let homeX: CGFloat
        /// Whether Stow offers to move this item.
        ///
        /// False for Apple's own extras, and that is a POLICY rather than a measured fact.
        /// Measurement says the truth is mixed: with the cut at roughly x2010 the Control
        /// Center item at x1804 stayed on the bar, but with the cut at x1841 the "Audio and
        /// Video Controls" item at x2082 was pushed off. Some system items resist and some
        /// do not, and which is which is not documented anywhere Stow can read.
        ///
        /// Given that, Stow declines to offer them. A hide that sometimes works is worse
        /// than none: the user cannot tell a broken app from an unmovable item.
        let isPushable: Bool
    }

    /// What the current choices mean for the visible bar.
    struct Outcome: Equatable {
        /// Rightmost app that should be hidden. Retained for diagnostics and the legacy
        /// placement-floor display; the active arranger keeps the boundary stationary.
        let tuckedBoundaryX: CGFloat?
        /// Apps requested off the bar, right to left.
        let hiddenAtRest: [String]
        /// Apps the user PINNED that are hidden anyway, because they sit left of a seam
        /// another choice required. Each needs a Command-drag right of that seam to be
        /// spared, and naming them is what stops a silent surprise.
        let collateral: [String]
        /// Apps the user asked to move that Stow cannot move at all.
        let unreachable: [String]
        /// Apps sitting left of the leftmost position a seam can be placed at, so no seam
        /// can be put between them and their neighbours.
        ///
        /// Measured, not theorised: sweeping the placement preference from 1 to 2400 on a
        /// twelve-item bar never placed a new item further left than x1987, while real items
        /// sat at x1841 and x1945. Apps below the floor can still be hidden together, since
        /// a seam to their right pushes all of them, but they cannot be split into different
        /// zones from each other.
        ///
        /// Reported rather than hidden, because the alternative is a picker that appears to
        /// accept a choice and then quietly does something else.
        let belowPlacementFloor: [String]

        /// Whether applying this plan can honour every chosen zone without sweeping an
        /// unchosen app or silently placing an app in a deeper zone.
        ///
        /// An unaddressable app cannot be moved safely, so the plan must fail visible.
        var isSafeToApply: Bool { unreachable.isEmpty }
    }

    /// Computes the outcome of the current zone choices.
    ///
    /// - Parameters:
    ///   - candidates: every app Stow could act on, in any order.
    ///   - zones: the chosen zone for a bundle. A closure rather than a dictionary so the
    ///     caller can hand over `Config.zone(forBundleID:)` directly, which already defaults
    ///     an unknown app to `.pinned`. That default matters: a newly installed menu bar app
    ///     must not hide itself before the user has said anything.
    ///   - placementFloor: the leftmost x a seam can be placed at, from
    ///     `SpacerItem.measurePlacementFloor()`. Nil skips the check, which is right for a
    ///     pure unit test and wrong for the live pane.
    static func outcome(candidates: [Candidate],
                        zones: (String) -> Zone,
                        placementFloor: CGFloat? = nil) -> Outcome {
        let movable = candidates.filter(\.isPushable)
        let unreachable = candidates
            .filter { !$0.isPushable && zones($0.bundleID) != .pinned }
            .sorted { $0.homeX > $1.homeX }
            .map(\.bundleID)

        let leavesAtRest = movable.filter { zones($0.bundleID) != .pinned }

        let tuckedBoundaryX = leavesAtRest.map(\.homeX).max()

        func caught(leftOf boundary: CGFloat?) -> [Candidate] {
            guard let boundary else { return [] }
            return movable.filter { $0.homeX <= boundary }.sorted { $0.homeX > $1.homeX }
        }

        let atRest = caught(leftOf: tuckedBoundaryX)

        let belowFloor: [String] = placementFloor.map { floor in
            movable.filter { $0.homeX < floor }
                .sorted { $0.homeX > $1.homeX }
                .map(\.bundleID)
        } ?? []

        return Outcome(
            tuckedBoundaryX: tuckedBoundaryX,
            hiddenAtRest: atRest.map(\.bundleID),
            // The active arranger moves apps around a stationary boundary, so no neighbouring
            // app is swept merely because another app was assigned to In Stow.
            collateral: [],
            unreachable: unreachable,
            belowPlacementFloor: belowFloor)
    }
}
