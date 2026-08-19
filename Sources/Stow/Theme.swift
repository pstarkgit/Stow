import SwiftUI

/// Stow's committed dark theme.
///
/// Surfaces, ink and hairline are inherited VERBATIM from AuthBar's `ABTheme` and
/// Murmur's `MTheme` so the three apps read as one family. Do not fork these values;
/// if the family palette changes it changes in all three.
///
/// The state gradients are NOT stored here. They read straight out of
/// `StowGlyph.paint(for:)`, so a change to the menu bar token's palette moves every
/// panel surface with it. That is the same one-source-of-truth arrangement `ABTheme`
/// uses, and it exists because the previous alternative was two lists of hexes that
/// silently disagreed.
enum StowTheme {
    // MARK: Surfaces
    static let canvas      = Color(red: 0.063, green: 0.071, blue: 0.086)   // #101216
    static let card        = Color(red: 0.086, green: 0.118, blue: 0.145)   // #161E25
    static let cardHover   = Color(red: 0.110, green: 0.150, blue: 0.185)
    static let hairline    = Color.white.opacity(0.07)

    // MARK: Ink
    static let ink         = Color(red: 0.906, green: 0.925, blue: 0.937)   // #E7ECEF
    static let inkSoft     = Color(red: 0.545, green: 0.580, blue: 0.612)   // #8B949C
    static let inkMuted    = Color(red: 0.353, green: 0.388, blue: 0.420)   // #5A636B

    // MARK: Accents shared with the siblings
    static let blue        = Color(red: 0.345, green: 0.651, blue: 1.0)     // #58A6FF
    static let orange      = Color(red: 0.980, green: 0.749, blue: 0.251)   // #FABF40
    static let rose        = Color(red: 0.949, green: 0.408, blue: 0.561)   // #F2688F

    // MARK: - State gradients, derived not retyped

    static func stops(for state: BarState) -> [Color] {
        StowGlyph.paint(for: state).stops.map(Color.init(nsColor:))
    }

    /// Left-to-right sweep, for gauges and the primary action.
    static func sweep(for state: BarState) -> LinearGradient {
        LinearGradient(colors: stops(for: state), startPoint: .leading, endPoint: .trailing)
    }

    /// Corner-to-corner sweep, matching the token's 315 degree angle.
    static func diagonal(for state: BarState) -> LinearGradient {
        LinearGradient(colors: stops(for: state),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The glow the panel's top rim and the sub-bar's top edge leak, in the state's
    /// own colour.
    static func edgeGlow(for state: BarState) -> Color {
        Color(nsColor: StowGlyph.paint(for: state).glow)
    }
}

/// Aurora surface tokens, inherited from AuthBar's `Aurora`.
enum Aurora {
    /// Sunken surface, for a control's own well. Deeper than the card it sits on,
    /// which is what makes a control read as inset rather than drawn on.
    static let inset = Color(red: 0.047, green: 0.055, blue: 0.071)   // #0C0E12
    /// Raised surface, for cards on the window canvas and sub-bar tiles.
    static let raised = Color(red: 0.090, green: 0.102, blue: 0.125)  // #171A20
    /// Dark ink for use on top of a bright Aurora gradient.
    static let onGradient = Color(red: 0.016, green: 0.067, blue: 0.051)
}
