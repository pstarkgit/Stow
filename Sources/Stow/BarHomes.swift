import AppKit
import CoreGraphics

/// Remembers where each app's status item sits when it is VISIBLE.
///
/// Needed because of an asymmetry that is easy to miss until a hidden app has to be
/// listed. A pushed item still exists and still reports a position, but that position is
/// far off the left of the screen and says nothing about where the item will land when it
/// comes back. So the moment the bar is hidden, Stow loses the only information it needs
/// to reason about the hidden apps: their real place in the order.
///
/// Without this, the Arrange pane can only list what is currently on the bar, which means
/// an app disappears from the list the moment it is hidden and can never be brought back
/// from there. That is the bug this type exists to remove.
///
/// Keyed by bundle identifier, and persisted, because both survive the owning app
/// relaunching and a window number does not.
@MainActor
enum BarHomes {

    /// Records the position of every item currently on the bar.
    ///
    /// Call this whenever a scan is taken with the bar REVEALED. Calling it while items
    /// are pushed would record their pushed positions as home, which is exactly the
    /// corruption this type prevents, so the caller must not.
    static func record(_ claims: [BarItemOwners.Owner]) {
        var homes = stored
        for claim in claims where !claim.bundleID.isEmpty {
            // Left edge only. Width is measured live and changes with an app's own
            // state, for example a clock that gets wider, so storing it would go stale
            // in a way the position does not.
            homes[claim.bundleID] = Double(claim.axLeftEdge)
        }
        stored = homes
    }

    /// Where this app's item sits when visible, if Stow has ever seen it on the bar.
    static func homeX(for bundleID: String) -> CGFloat? {
        stored[bundleID].map { CGFloat($0) }
    }

    /// Every app Stow has ever seen on the bar, with its home position.
    static var all: [String: CGFloat] {
        stored.mapValues { CGFloat($0) }
    }

    /// Forgets an app, for when it is uninstalled and should stop appearing in the list.
    static func forget(_ bundleID: String) {
        var homes = stored
        homes.removeValue(forKey: bundleID)
        stored = homes
    }

    // MARK: - storage

    /// `UserDefaults` rather than `Config`.
    ///
    /// This is observed geometry, not a user decision. `Config` is the user's policy and
    /// is worth showing them, diffing, and putting in a named profile; a table of
    /// measured x positions is none of those things, and mixing it in would put machine
    /// state into a file whose whole value is that it holds intent.
    private static let key = "dev.starkpat.stow.itemHomeX"
    private static let legacyKey = "dev.starkpat.airlock.itemHomeX"

    private static var stored: [String: Double] {
        get {
            if let current = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
                return current
            }
            if let legacy = UserDefaults(suiteName: "dev.starkpat.airlock")?
                .dictionary(forKey: legacyKey) as? [String: Double] {
                UserDefaults.standard.set(legacy, forKey: key)
                return legacy
            }
            return [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
