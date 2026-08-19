import AppKit

/// Stow's five states.
///
/// Colour and motion carry the state; the SHAPE never changes between them. That
/// rule is inherited from `AuthBarGlyph` and `MurmurGlyph` and it is load-bearing:
/// at 18 px a glyph that morphs reads as a rendering glitch, while a glyph that
/// recolours reads as status.
enum BarState: Equatable, Sendable {
    /// Collapsed, hidden run stowed, headroom fine. The state you should barely
    /// notice. Lime to teal to indigo, steady, no motion.
    case tidy
    /// The sub-bar is showing, or an item is currently on the stage. Same hues,
    /// lifted, so "something is out" reads without a shape change.
    case open
    /// Headroom is below one item's width, so even a plus-one reveal would clip.
    /// DETECTED from `BarBudget`, never guessed. Gold to orange to pink.
    case crowded
    /// Items are being moved between zones. Borrows AuthBar's `.authenticating`
    /// paint deliberately: it is the same "a thing is in flight" semantic.
    case arranging
    /// Accessibility is denied, so no reveal is possible at all. Slate, unlit.
    /// Honest about being unable to work rather than implying health.
    case blocked

    /// States whose artwork depends on a live phase and therefore cannot be
    /// cached. Everything else is drawn once and reused.
    var isAnimated: Bool {
        switch self {
        case .crowded, .arranging: return true
        case .tidy, .open, .blocked: return false
        }
    }
}

/// Draws the Stow mark: a menu bar with two visible app tiles and one tile
/// stowed beneath it, wearing a per-state Aurora gradient.
///
/// Hand-drawn rather than an SF Symbol, for the same three reasons `AuthBarGlyph`
/// and `MurmurGlyph` are:
///   1. `paletteColors` on a multi-layer symbol gives flat per-layer colours,
///      never one gradient sweeping the whole mark.
///   2. The slot in the stowed tile is a true cutout (even-odd), so the mark
///      stays legible on both light and dark menu bars.
///   3. One geometry function serves the 18 pt bar glyph and the 1024 px app icon,
///      so the two can never visually drift apart.
///
/// The displaced lower tile is the behavior, not a metaphor: selected apps move
/// below the visible bar and remain available to return.
enum StowGlyph {

    /// Design grid. The mark's proportions are expressed in these units.
    ///
    /// Back to the design's 22 now that SIZE is controlled by `bodyFill` instead. Lowering the
    /// grid was the wrong lever and it ran out: the body occupied units 2.5 to 19.5, so any grid
    /// below 19.5 pushed it past the canvas edge, and 19.5 only reached 78% fill where the
    /// neighbours need about 88%.
    static let grid: CGFloat = 22

    /// How much of the available box the geometry grid fills, as a fraction.
    ///
    /// Apparent size is ultimately controlled by the ink bounds inside this grid.
    /// Keeping the grid full-size avoids compounding its margin with the image's
    /// own 6% rendering inset.
    static let bodyFill: CGFloat = 1.0

    /// The freestanding mark needs almost the full menu-bar canvas. The old 6%
    /// inset compounded with the whitespace inside the behavior mark and made
    /// it visibly smaller than neighboring status icons.
    static let renderInsetFraction: CGFloat = 0.01

    /// Menu bar artwork is 18 pt, NSStatusItem's usable height. Square, because
    /// the token is square.
    static let menuBarSize = NSSize(width: 18, height: 18)

    // MARK: - Geometry

    /// The mark with an even-odd slot cut out of the stowed tile.
    static func tokenPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.append(bodyPath(in: rect))
        path.append(markPath(in: rect))
        path.windingRule = .evenOdd
        return path
    }

    /// The mark's outer silhouette WITHOUT the cutout.
    ///
    /// The glow must be cast from THIS, not from the holed path. A shadow is drawn
    /// behind its shape, so a hole lets the bloom through and fills the channel with
    /// soft colour. AuthBar measured this: the keyhole centre sampled a=0.37 instead
    /// of a=0.00 before the split. Same trap here.
    static func bodyPath(in rect: NSRect) -> NSBezierPath {
        let body = bodyRect(in: rect)
        let path = NSBezierPath()

        let bar = NSRect(x: body.minX + body.width * 0.04,
                         y: body.minY + body.height * 0.37,
                         width: body.width * 0.92,
                         height: body.height * 0.24)
        path.appendRoundedRect(bar, xRadius: bar.height / 2, yRadius: bar.height / 2)

        for x in [0.18, 0.48] {
            let tile = NSRect(x: body.minX + body.width * x,
                              y: body.minY + body.height * 0.69,
                              width: body.width * 0.25,
                              height: body.height * 0.25)
            path.appendRoundedRect(tile,
                                   xRadius: body.width * 0.055,
                                   yRadius: body.width * 0.055)
        }

        let stowed = NSRect(x: body.minX + body.width * 0.61,
                            y: body.minY + body.height * 0.06,
                            width: body.width * 0.31,
                            height: body.height * 0.31)
        path.appendRoundedRect(stowed,
                               xRadius: body.width * 0.065,
                               yRadius: body.width * 0.065)
        return path
    }

    /// The body's square, centred in `rect` at `bodyFill` of its shorter side.
    ///
    /// Split out so every element scales from the same square at menu-bar and app-icon sizes.
    static func bodyRect(in rect: NSRect) -> NSRect {
        let side = min(rect.width, rect.height) * bodyFill
        return NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                      width: side, height: side)
    }

    static func artworkRect(in rect: NSRect) -> NSRect {
        let pad = min(rect.width, rect.height) * renderInsetFraction
        return rect.insetBy(dx: pad, dy: pad)
    }

    /// A small horizontal slot inside the stowed tile.
    static func markPath(in rect: NSRect) -> NSBezierPath {
        let body = bodyRect(in: rect)
        let slot = NSRect(x: body.minX + body.width * 0.65,
                          y: body.minY + body.height * 0.19,
                          width: body.width * 0.23,
                          height: body.height * 0.07)
        return NSBezierPath(roundedRect: slot,
                            xRadius: slot.height / 2,
                            yRadius: slot.height / 2)
    }

    // MARK: - Palette
    //
    // Aurora Lime is Stow's identity lane. AuthBar owns emerald/cyan/blue plus
    // gold/orange/pink plus red/pink/violet; Murmur owns magenta/violet/sky. The
    // `.crowded` and `.arranging` stops are borrowed from AuthBar ON PURPOSE, since
    // they carry the same semantics across the family. Only `.tidy` and `.open` are
    // Stow's own, and those are what the identity is.

    struct Paint: Sendable {
        let stops: [NSColor]
        let glow: NSColor
        let glowRadius: CGFloat
    }

    static func paint(for state: BarState) -> Paint {
        switch state {
        case .tidy:
            return Paint(stops: [hex(0xA3E635), hex(0x14B8A6), hex(0x4F46E5)],
                         glow: hex(0x2DD4BF, alpha: 0.55), glowRadius: 7)
        case .open:
            return Paint(stops: [hex(0xBEF264), hex(0x2DD4BF), hex(0x6366F1)],
                         glow: hex(0x2DD4BF, alpha: 0.70), glowRadius: 8)
        case .crowded:
            return Paint(stops: [hex(0xFBBF24), hex(0xFB7C3C), hex(0xF472B6)],
                         glow: hex(0xFB923C, alpha: 0.55), glowRadius: 7)
        case .arranging:
            return Paint(stops: [hex(0x8B5CF6), hex(0x22D3EE), hex(0x8B5CF6)],
                         glow: hex(0xA78BFA, alpha: 0.65), glowRadius: 9)
        case .blocked:
            return Paint(stops: [hex(0x475569), hex(0x64748B)],
                         glow: .clear, glowRadius: 0)
        }
    }

    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: alpha)
    }

    // MARK: - Rendering

    /// Artwork for a state.
    ///
    /// - Parameters:
    ///   - state: which bar state to draw.
    ///   - size: canvas size; defaults to menu bar size.
    ///   - phase: 0...1 animation phase. Drives the arranging sweep and the crowded
    ///     glow simmer; ignored by steady states.
    ///   - glow: whether to bloom. Off for the app icon, where the tile fills the
    ///     canvas and a glow would clip at the edges.
    ///   - glowScale: multiplier on the design's glow radius. The 7-unit bloom was
    ///     authored against a 36 px chip; at 18 px that is wider than the token's own
    ///     corner radius and smudges on a LIGHT menu bar. Same empirical 0.45 AuthBar
    ///     landed on.
    static func image(for state: BarState,
                      size: NSSize = menuBarSize,
                      phase: CGFloat = 0,
                      glow: Bool = true,
                      glowScale: CGFloat = 0.45) -> NSImage {
        let paint = paint(for: state)
        let image = NSImage(size: size, flipped: false) { rect in
            // Constant inset, independent of `glow`. Tying it to the glow made
            // AuthBar's token render LARGER whenever the bloom was off, so the mark
            // changed size between states. The room is reserved either way.
            let box = artworkRect(in: rect)
            let path = tokenPath(in: box)

            if glow, paint.glowRadius > 0 {
                // The crowded simmer modulates the GLOW's alpha, never the token's
                // opacity or size. A pulsing size in the menu bar shifts every item
                // to its right, which is intolerable; a pulsing token opacity reads
                // as "disabled" rather than "full".
                var glowAlpha = paint.glow.alphaComponent
                if state == .crowded {
                    glowAlpha *= 0.55 + 0.45 * (0.5 + 0.5 * cos(phase * 2 * .pi))
                }
                let shadow = NSShadow()
                shadow.shadowColor = paint.glow.withAlphaComponent(glowAlpha)
                shadow.shadowBlurRadius = paint.glowRadius * glowScale
                    * (min(rect.width, rect.height) / grid)
                shadow.shadowOffset = .zero
                NSGraphicsContext.saveGraphicsState()
                shadow.set()
                // Cast from the SOLID body, never the holed token.
                paint.stops.first?.setFill()
                bodyPath(in: box).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // ONE gradient across the whole token. Per-element gradients band and
            // lose the sweep.
            let gradient = NSGradient(colors: paint.stops)
                ?? NSGradient(colors: [.gray, .gray])!
            // 315 degrees puts the first stop top-left and the last bottom-right.
            gradient.draw(in: box, angle: 315)

            if state == .arranging {
                // A highlight sweeps the token, clipped to it, so waiting animates
                // the identity rather than adding a spinner.
                let c = NSPoint(x: box.midX, y: box.midY)
                let angle = phase * 2 * .pi
                let reach = max(box.width, box.height)
                let sweep = NSBezierPath()
                sweep.move(to: c)
                sweep.appendArc(withCenter: c, radius: reach,
                                startAngle: (angle * 180 / .pi) - 34,
                                endAngle: (angle * 180 / .pi) + 34)
                sweep.close()
                NSColor.white.withAlphaComponent(0.30).setFill()
                sweep.fill()
            }
            NSGraphicsContext.restoreGraphicsState()

            // The glow pass filled the SOLID body, which leaves opaque colour where
            // the stow should be. Punch it out AFTER restoring, since the clip above
            // would otherwise block the erase.
            if glow, paint.glowRadius > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                markPath(in: box).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        // Template images get force-recoloured monochrome by macOS, which would
        // discard every gradient here.
        image.isTemplate = false
        return image
    }
}
