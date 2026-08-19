import AppKit

/// Which side of Stow's single boundary an app belongs on.
///
/// Older builds persisted a third `"vaulted"` value. It is accepted on decode and
/// migrated to `.tucked`, but Stow never writes or exposes that unsafe state again.
enum Zone: String, CaseIterable, Sendable {
    /// Always in the bar. Never pushed off.
    case pinned
    /// Off the bar at rest, available from Stow and restored by Show Everything.
    case tucked
}

extension Zone: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Zone.pinned.rawValue:
            self = .pinned
        case Zone.tucked.rawValue, "vaulted":
            self = .tucked
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown Stow zone: \(value)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One status item as observed in the window server.
///
/// `frame` is in Quartz global display coordinates (origin top-left), which is what
/// `kCGWindowBounds` reports. Convert before handing to AppKit.
struct ObservedItem: Identifiable, Sendable {
    /// `kCGWindowNumber`. Stable for the lifetime of the item's window.
    let windowNumber: CGWindowID
    /// `kCGWindowOwnerPID`. On macOS 26 this is Control Center's pid for EVERY
    /// status item, third-party included, because Control Center HOSTS the
    /// item's window without owning it. Resolving an icon or a name from THIS
    /// pid reproduces the exact bug that finding uncovered: one identical
    /// Control Center icon and one identical "Control Center" name down the
    /// whole list. Use `owner(in:)`, `displayName(in:)` or `icon(in:)`
    /// instead, which ask the real owning application via `BarItemOwners`.
    let ownerPID: pid_t
    /// Resolved from the pid. Nil for items whose owner has since exited.
    let bundleID: String?
    /// Best available human name. Falls back to the pid when the owner is unknown.
    let ownerName: String
    /// `kCGWindowBounds`. May sit OUTSIDE the visible bar when pushed by the spacer,
    /// which is the entire premise of reveal-one and the subject of the probe.
    let frame: CGRect
    /// Whether `frame` currently intersects the display's visible menu bar rect.
    let isOnScreen: Bool

    var id: CGWindowID { windowNumber }

    /// The item's real owning application, resolved via `BarItemOwners` rather
    /// than from `ownerPID`. `BarItemOwners.claims()` walks every running
    /// application's OWN `AXExtrasMenuBar`, which is the one place a status
    /// item's real owner still answers for it: the window server only ever
    /// reports Control Center, which hosts every item without owning any of
    /// them. Nil when no running application claims a position near this
    /// item's frame.
    @MainActor
    func owner(in claims: [BarItemOwners.Owner]) -> BarItemOwners.Owner? {
        BarItemOwners.owner(of: frame, in: claims)
    }

    /// A name safe to show a user, or nil when no application claims this item.
    ///
    /// `ownerName` is never the answer here: it is derived from `ownerPID`,
    /// which is Control Center for every item on this OS, so rendering it
    /// would label the user's entire bar "Control Center". This resolves
    /// through the item's REAL owner instead, which is why a caller must say
    /// "Unidentified item" on nil rather than falling back to `ownerName`,
    /// which would silently restate the same wrong answer.
    @MainActor
    func displayName(in claims: [BarItemOwners.Owner]) -> String? {
        owner(in: claims)?.name
    }

    /// The item's real app icon, resolved through its real owning pid.
    ///
    /// An earlier version of this project read
    /// `NSRunningApplication(processIdentifier: ownerPID)?.icon` and reasoned
    /// that this would show Dropbox's icon for Dropbox's item, with no Screen
    /// Recording grant needed. That reasoning depended on the status item
    /// window reporting its real owner, and it does not: every status item on
    /// macOS 26 is attributed to Control Center, so that call returns Control
    /// Center's icon for the whole bar, one identical glyph repeated down the
    /// list, which is worse than showing none because it looks like real data.
    /// `BarItemOwners.claims()` recovers the actual owner by asking each
    /// running application for its own `AXExtrasMenuBar`, so resolving the
    /// icon through THAT pid is the item's real app icon, no ScreenCaptureKit
    /// or TCC prompt required. Nil when no application claims this item;
    /// callers should fall back to a role glyph rather than draw nothing.
    @MainActor
    func icon(in claims: [BarItemOwners.Owner]) -> NSImage? {
        guard let owner = owner(in: claims) else { return nil }
        return NSRunningApplication(processIdentifier: owner.pid)?.icon
    }
}

/// How Stow can activate a given item, cheapest first.
///
/// Cached per bundle ID by `PressActionProbe`, because the expensive path should only
/// run for items that genuinely need it.
enum RevealPath: String, Codable, Sendable {
    /// The item exposes `kAXPressAction`. Its menu opens with ZERO reveal: no spacer
    /// change, no relayout wait, no timing window. Nothing else has to happen.
    case pressAction
    /// No press action. Shrink the spacer by exactly this item's width, wait for it
    /// to land on the stage, synthesize a click, wait for close, re-expand.
    case revealOne
    /// Neither path is available: Accessibility is denied, or the frame could not be
    /// read. Surfaced honestly rather than retried forever.
    case unavailable
}
