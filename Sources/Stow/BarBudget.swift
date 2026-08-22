import Foundation
import CoreGraphics

/// How much menu bar you actually have, in POINTS.
///
/// Measured, never counted. v1 of the design reported "11 of 14 slots", which is
/// wrong for a concrete reason: AuthBar's bar label is a glyph PLUS a countdown, so
/// it is two to three times the width of a plain glyph. A slot count reports room
/// that does not exist.
///
/// Deliberately a pure value type with no AppKit dependency in its arithmetic, so
/// every branch is testable without a window server. The measuring lives in
/// `BarScanner` and `MenuWidthProbe`; the deciding lives here.
struct BarBudget: Equatable, Sendable {

    /// Real, visible menu-bar items suitable for user-facing rows and occupancy.
    /// Exact seam ids are preferred; the display-width ceiling handles a spacer
    /// owned by another process whose private window id is unavailable.
    nonisolated static func ordinaryItems(in items: [ObservedItem],
                                          screenWidth: CGFloat,
                                          excluding seamWindows: Set<CGWindowID>) -> [ObservedItem] {
        items.filter(\.isOnScreen)
            .filter { !seamWindows.contains($0.windowNumber) }
            .filter { $0.frame.width > 0 && $0.frame.width <= screenWidth }
    }

    /// Widths that represent ordinary menu-bar occupants rather than spacer
    /// mechanisms. An expanded boundary can intersect the display and therefore
    /// report `isOnScreen == true` while being several displays wide. A separate
    /// diagnostic process cannot know that boundary's private window number, but
    /// it can reject a width larger than the display because no ordinary status
    /// item can legally consume more than the complete menu bar.
    nonisolated static func occupiedWidths(in items: [ObservedItem],
                                           screenWidth: CGFloat,
                                           excluding seamWindows: Set<CGWindowID>) -> [CGFloat] {
        ordinaryItems(in: items, screenWidth: screenWidth, excluding: seamWindows)
            .map(\.frame.width)
    }

    /// Full width of the display's menu bar.
    let screenWidth: CGFloat
    /// Width consumed by the FRONTMOST app's menu titles.
    ///
    /// This is the field that makes capacity move under you. Finder gives five short
    /// titles; Xcode gives nine; Logic is worse. The same reveal fits at 10:00 with
    /// Finder in front and clips at 10:05 with Xcode in front, with no user action
    /// and no explanation. Which is why the budget is recomputed on every
    /// frontmost-app change, not once at launch.
    let appMenuWidth: CGFloat
    /// Width of the notch dead zone. Zero on a notchless display.
    ///
    /// Not merely hidden space: an item clipped into the notch is unclickable, which
    /// is strictly worse than being stowed.
    let notchWidth: CGFloat
    /// Clock, Control Center, Siri. Not ours to move, hide or reorder.
    let systemTrailingWidth: CGFloat
    /// Measured widths of every ordinary item currently in the bar. Callers that
    /// own spacer seams exclude those mechanism windows before constructing a budget.
    let occupiedWidths: [CGFloat]

    /// Space a status item could legally occupy on this display right now.
    var usable: CGFloat {
        max(0, screenWidth - appMenuWidth - notchWidth - systemTrailingWidth)
    }

    var inUse: CGFloat { occupiedWidths.reduce(0, +) }

    /// Points left over. Can go negative, and that is a real state rather than an
    /// error: macOS will already be clipping when it does.
    var headroom: CGFloat { usable - inUse }

    /// Whether a single item of this width can surface onto the stage without macOS
    /// clipping something.
    ///
    /// A plus-one delta, deliberately. "Shrink the spacer to zero" would drag the
    /// whole tucked run back in and reintroduce the overflow this design exists to
    /// avoid.
    func canReveal(width: CGFloat) -> Bool {
        width > 0 && headroom >= width
    }

    /// The bar state this budget implies.
    ///
    /// `.crowded` means "even a plus-one reveal would clip", which is a DETECTED
    /// condition, not a guess. Callers pass the widest item they might need to
    /// surface; passing nil means nothing is tucked, so crowding cannot bite.
    func state(widestTucked: CGFloat?) -> BarState {
        guard let widest = widestTucked, widest > 0 else {
            return headroom < 0 ? .crowded : .tidy
        }
        return canReveal(width: widest) ? .tidy : .crowded
    }

    /// One line for the panel's BAR BUDGET caption and for `--probe` output.
    var arithmetic: String {
        let f = { (v: CGFloat) in String(Int(v.rounded())) }
        return "\(f(screenWidth)) - \(f(appMenuWidth)) app menus"
             + " - \(f(notchWidth)) notch - \(f(systemTrailingWidth)) system"
             + " = \(f(usable)) usable · \(f(inUse)) in use · \(f(headroom)) free"
    }
}
