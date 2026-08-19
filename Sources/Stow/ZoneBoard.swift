import AppKit
import SwiftUI

/// The Arrange surface: two zones stacked vertically, icons dragged between them.
///
/// Replaces a list of rows with pickers. That list was the wrong shape for this app and it
/// was reported as such: menu bar management is SPATIAL, so the control should be spatial
/// too. Ice and Bartender both present their zones as regions you drag icons across, and
/// the reason is not fashion: a zone is a place on a bar, and a picker in a table row hides
/// that fact behind a word.
///
/// Two drop regions, top to bottom, in the order the bar reads from the right:
///
///     SHOWN    always on the bar
///     TUCKED   off at rest, back on a reveal
///
/// Dragging a tile between regions sets that app's zone. The consequence, which the list
/// could only state in a paragraph, is visible here: a seam is drawn between the regions,
/// and an app that will be swept off by someone else's seam is marked in place.
///
/// What this cannot do, and does not pretend to: reorder another app's icon. No API moves
/// another app's status item and a synthesised Command-drag was measured leaving one exactly
/// where it started. So dragging changes which ZONE an app belongs to, not where it sits
/// among its neighbours, and where a zone cannot be honoured the tile says so.
struct ZoneBoard: View {

    /// One app as the board draws it.
    struct Tile: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        let widthPt: CGFloat?
        let isOnBarNow: Bool
        /// Pinned, yet a seam will sweep it off anyway.
        let isCollateral: Bool
        /// Sits further left than macOS lets a seam be placed, so its zone cannot be
        /// separated from its neighbours'.
        let isBelowFloor: Bool

        var id: String { bundleID }
    }

    let tiles: [Tile]
    /// The zone each app is assigned to right now.
    let zoneOf: (String) -> Zone
    /// Called when a tile is dropped into a different zone.
    let onMove: (String, Zone) -> Void

    @State private var hovering: Zone?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            zone(.pinned, title: "ON BAR", subtitle: "always visible")
            seam(label: "stow boundary")
            zone(.tucked, title: "IN STOW", subtitle: "hidden at rest, back when opened")
        }
    }

    // MARK: - zones

    private func zone(_ zone: Zone, title: String, subtitle: String) -> some View {
        let members = tiles.filter { zoneOf($0.bundleID) == zone }
        let isTarget = hovering == zone

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(StowTheme.inkSoft)
                    .kerning(1.2)
                Text("\(members.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(StowTheme.inkMuted)
                Spacer()
            }

            // A wrapping row of tiles, not a column of rows: this is a picture of a bar, and
            // a bar runs sideways.
            if members.isEmpty {
                Text("drag an app here")
                    .font(.system(size: 10.5))
                    .foregroundStyle(StowTheme.inkMuted.opacity(isTarget ? 1 : 0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                FlowRow(spacing: 8) {
                    ForEach(members) { tile in
                        TileView(tile: tile)
                            .draggable(tile.bundleID) {
                                // Drag preview: the icon alone, so what is being moved is
                                // unmistakable even over another region.
                                TileView(tile: tile).opacity(0.9)
                            }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTarget ? StowTheme.cardHover : StowTheme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTarget ? AnyShapeStyle(StowTheme.sweep(for: .tidy))
                                       : AnyShapeStyle(StowTheme.hairline),
                              lineWidth: isTarget ? 1.5 : 1))
        .dropDestination(for: String.self) { dropped, _ in
            // Drops are ACCEPTED while seams are moving. Rejecting them made a drag during that
            // window silently do nothing, which on a bar that takes seconds to settle is most of
            // the time the user is actually dragging. The apply is coalesced instead, so a drop
            // landing mid-move records the zone at once and folds into the next settle.
            guard let bundle = dropped.first else { return false }
            guard zoneOf(bundle) != zone else { return false }
            onMove(bundle, zone)
            return true
        } isTargeted: { targeted in
            hovering = targeted ? zone : (hovering == zone ? nil : hovering)
        }
    }

    /// A seam drawn between two regions.
    ///
    /// This is the one piece of Stow's chrome that belongs in a picture rather than in the
    /// bar. The seam in the real menu bar is invisible on purpose, the way Ice's and
    /// Bartender's spacers are; drawing it HERE is how the user sees where the boundary is
    /// without spending bar space on a decoration.
    private func seam(label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(StowTheme.sweep(for: .tidy))
                .kerning(0.8)
            Rectangle()
                .fill(StowTheme.sweep(for: .tidy))
                .frame(height: 2)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
    }
}

// MARK: - one tile

/// One app on the board: its real icon, its name, and any consequence it carries.
private struct TileView: View {
    let tile: ZoneBoard.Tile

    var body: some View {
        HStack(spacing: 7) {
            if let icon = tile.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .opacity(tile.isOnBarNow ? 1 : 0.5)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(StowTheme.inkMuted)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(StowTheme.ink)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(captionTint)
                        .lineLimit(1)
                }
            }
            if let width = tile.widthPt {
                Text("\(Int(width))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Aurora.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderTint, lineWidth: 1))
        .help(helpText)
    }

    /// The one thing worth saying under the name, chosen by severity rather than stacked.
    /// Three captions on one tile would be noise; the worst one is the actionable one.
    private var caption: String? {
        if tile.isBelowFloor { return "macOS limit" }
        if tile.isCollateral { return "hidden anyway" }
        if !tile.isOnBarNow { return "off the bar" }
        return nil
    }

    private var captionTint: Color {
        if tile.isBelowFloor { return StowTheme.inkSoft }
        if tile.isCollateral { return StowTheme.orange }
        return StowTheme.inkMuted
    }

    private var borderTint: Color {
        if tile.isCollateral { return StowTheme.orange.opacity(0.55) }
        return StowTheme.hairline
    }

    private var helpText: String {
        if tile.isBelowFloor {
            return "\(tile.name) sits further left than macOS lets Stow place a seam, so its"
                + " zone cannot be separated from its neighbours'. Command-drag it to the"
                + " right in the menu bar."
        }
        if tile.isCollateral {
            return "\(tile.name) is set to stay, but sits left of a seam your other choices"
                + " need, so it will be hidden anyway. Command-drag it right of that seam."
        }
        return tile.name
    }
}

// MARK: - layout

/// A row that wraps, so a zone with many apps grows downwards instead of clipping.
///
/// Hand-rolled rather than `LazyVGrid`, because a grid imposes equal column widths and these
/// tiles are deliberately different widths: an app with a long name should not force every
/// other tile to match it.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
