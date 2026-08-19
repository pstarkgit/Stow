import CoreGraphics
import Foundation

/// Which items a hide will remove, given where the cut sits.
///
/// Pure, and separate from the view, because this is the classification a user reads
/// as correct or broken: a row shown under HIDES that then stays on the bar is the
/// most confusing failure this app can produce. Inline in a SwiftUI body it could not
/// be tested at all.
///
/// The rule is the mechanism, not a policy choice. A status item pushes only what is
/// to its LEFT, so an item hides exactly when it sits at or left of the cut. Verified
/// end to end by `Stow --cut`: with the cut at x2119, the five items at x1729 through
/// x2093 all left the bar and the two at x2125 and x2171 both stayed, with zero items
/// on the wrong side.
enum BarCut {

    /// One item's fate under the current cut.
    struct Split {
        /// Items right of the cut. These survive a hide.
        let staying: [ObservedItem]
        /// Items at or left of the cut that Stow can genuinely push off the bar.
        let hiding: [ObservedItem]
        /// Items at or left of the cut that stay anyway, because Stow cannot move
        /// them.
        ///
        /// This bucket exists because of a measured mismatch, not a theory. With the
        /// cut placed right of Outlook, and again right of zoom.us, the Control Center
        /// item at x1804 was on the hidden side both times and stayed on the bar both
        /// times. Apple's own extras are laid out by the system and a third-party
        /// status item does not push them.
        ///
        /// Listing them under `hiding` would make the pane promise something it cannot
        /// deliver, which is worse than admitting the limit: the user would press hide,
        /// watch an icon stay, and have no way to tell whether Stow was broken.
        let unhidable: [ObservedItem]
    }

    /// Sorts `items` onto the sides of `cutX`.
    ///
    /// - Parameters:
    ///   - items: on-bar items, in any order. Sorted right to left in the result,
    ///     because the outermost item is the one furthest right and reading the list
    ///     in that direction is what makes "left of the cut" mean the rows below it.
    ///   - cutX: the seam's measured left edge, or nil when the seam has not been
    ///     placed yet.
    ///   - excluding: window numbers to drop entirely. Stow's own seam belongs here:
    ///     it resolves to the name "Stow" exactly as Stow's token does, so leaving it
    ///     in listed Stow twice and offered to cut at the cut.
    ///   - unpushable: window numbers Stow cannot move, which in practice is Apple's
    ///     own extras. Passed in rather than decided here so this stays pure and the
    ///     caller keeps the one owners walk it already did.
    /// - Returns: the split. With no cut, every pushable item is reported as hiding,
    ///   because a seam that has not been placed sits at the far right of the bar by
    ///   default and would push the whole run. Reporting nothing as hiding would
    ///   understate what a press of the button is about to do.
    static func split(items: [ObservedItem],
                      cutX: CGFloat?,
                      excluding excluded: Set<CGWindowID> = [],
                      unpushable: Set<CGWindowID> = []) -> Split {
        let ordered = items
            .filter { !excluded.contains($0.windowNumber) }
            .sorted { $0.frame.minX > $1.frame.minX }

        let onHiddenSide: (ObservedItem) -> Bool = { item in
            guard let cutX else { return true }
            return item.frame.minX <= cutX
        }

        var staying: [ObservedItem] = []
        var hiding: [ObservedItem] = []
        var unhidable: [ObservedItem] = []
        for item in ordered {
            if !onHiddenSide(item) {
                staying.append(item)
            } else if unpushable.contains(item.windowNumber) {
                unhidable.append(item)
            } else {
                hiding.append(item)
            }
        }
        return Split(staying: staying, hiding: hiding, unhidable: unhidable)
    }
}
