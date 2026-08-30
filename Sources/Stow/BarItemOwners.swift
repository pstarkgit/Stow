import AppKit
import ApplicationServices
import CoreGraphics

/// Resolves which application actually owns each status item in the menu bar.
///
/// This exists because the window server will not tell you. On macOS 26 every
/// status item window reports the Control Center process as its
/// `kCGWindowOwnerPID`, so `ObservedItem.ownerName` is "Control Center" for all of
/// them and `kCGWindowName` is the literal string "Item-0" for every third-party
/// one. An earlier version of this project concluded from that pair of facts that
/// per-item identity was simply unavailable on this OS, and shipped a panel
/// showing eleven rows reading "Unidentified item".
///
/// That conclusion was wrong, and the mistake was asking the wrong process.
/// Control Center HOSTS the items but does not own them. Each owning application
/// still answers for its own: ask any running app for its `AXExtrasMenuBar` and it
/// reports its own status items with a real position and size, exactly as
/// `PressActionProbe` already asks per pid. Iterating every running application
/// therefore recovers the full picture: a real name, a real bundle id, and the
/// real owning pid, which is also the route back to a real per-app icon.
///
/// Measured on macOS 26.6.1 with 17 items in the bar: 15 resolved to a named
/// owning application, including 1Password, Outlook, zoom.us, NoteBuddy, AuthBar
/// and Murmur.
@MainActor
enum BarItemOwners {

    /// One application's claim to a status item at a position.
    struct Owner: Sendable, Equatable {
        /// Human name, from `NSRunningApplication.localizedName`.
        let name: String
        /// Bundle identifier. THE stable key: unlike a window number it survives a
        /// relaunch, which is what makes per-app zone membership persistable.
        let bundleID: String
        /// The real owning process, not Control Center. The route to a real icon.
        let pid: pid_t
        /// The item's own left edge as the owning app reports it, in Quartz global
        /// coordinates.
        let axLeftEdge: CGFloat
    }

    /// Every on-screen status item claimed by a running application.
    ///
    /// A FILTER over `identities()`, not a second walk. The two bodies were byte-identical apart
    /// from one predicate, so this was 27 copied lines of accessibility traversal: the
    /// `.prohibited` skip, the messaging timeout, the extras and children fetch, and the `Owner`
    /// construction. `Owner.axLeftEdge` is assigned that same `origin.x`, so the relationship is
    /// exact rather than approximate.
    ///
    /// The two CACHES stay separate, which is a different question and the file already argues it
    /// correctly below: the two answer different questions at different call sites, and a caller of
    /// one must not inherit the other's staleness window. Only the walk was duplicated.
    ///
    /// Skips a non-positive x or a zero width. Both occur in practice: several apps report `x = -1`
    /// or a large negative x for an item that is present but currently has no usable position, and
    /// Control Center reports a run of zero-size children that are placeholders rather than items.
    /// A zero width is rejected by `identities()` itself, as not being an item at all; the position
    /// test is what this adds, and `isPushedOffScreen` is the shared spelling of it.
    static func claims() -> [Owner] {
        identities().filter { $0.axLeftEdge > 0 }
    }

    /// Every application that OWNS a status item, regardless of where that item
    /// currently sits.
    ///
    /// `claims()` filters to `origin.x > 0` because that is the right question for
    /// POSITIONING: a claim with no usable x cannot be matched to a window. It is the
    /// wrong question for IDENTITY, and conflating the two is why a currently-hidden
    /// app used to vanish from Stow entirely. Measured with 17 items in the bar:
    /// OneDrive owns one at x-8958, which is real width at a real (if off-screen)
    /// position, not a placeholder. Only Control Center's zero-size children, which
    /// `claims()` also rejects on `size.width > 0`, are genuinely not items.
    ///
    /// So this keeps the width filter, which is the only one distinguishing a real
    /// item from a placeholder, and drops the position filter. A caller that needs to
    /// reason about where the item sits reads `axLeftEdge` itself and applies
    /// `isPushedOffScreen`.
    static func identities() -> [Owner] {
        guard PressActionProbe.isTrusted else { return [] }

        var found: [Owner] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

            guard let extras = element(of: attribute(axApp, "AXExtrasMenuBar")),
                  let children = attribute(extras, kAXChildrenAttribute as String)
                    as? [AXUIElement]
            else { continue }

            for child in children {
                guard let origin = position(of: child),
                      let size = size(of: child),
                      size.width > 0
                else { continue }
                found.append(Owner(name: itemName(of: child, in: app),
                                   bundleID: app.bundleIdentifier ?? "",
                                   pid: app.processIdentifier,
                                   axLeftEdge: origin.x))
            }
        }
        return found
    }

    /// Whether an `axLeftEdge` describes an item Stow itself has swept off the visible
    /// bar, as opposed to one that simply has no usable position.
    ///
    /// Both read as negative, and they are not the same condition. Measured across 17
    /// items: six report exactly `x = -1` with no seam involved at all (LogiTune,
    /// HP Secure Print, several background helpers, DisplayLink Manager), which is a
    /// sentinel for "no position", not a location. Four sit far to the left instead,
    /// hundreds to thousands of points off-screen (OneDrive x-8958, Vendor Agent x-3934,
    /// zoom.us x-3966, Backdrop x-8890), which is exactly what a seam pushing ~5,000pt
    /// produces: a real position, just off the visible bar.
    ///
    /// The threshold sits directly between the two clusters rather than at zero, so a
    /// sentinel never reads as a push. `nonisolated`: pure arithmetic over its own
    /// argument, so a test drives it without a bar or an accessibility grant.
    nonisolated static func isPushedOffScreen(_ axLeftEdge: CGFloat) -> Bool {
        axLeftEdge < -1
    }

    /// Whatever `identities()` last resolved, without walking anything. Empty before
    /// the first walk completes, the same "not known yet" contract as
    /// `lastKnownClaims`.
    static var lastKnownIdentities: [Owner] { cachedIdentities }

    /// `identities()` from cache when the set of running applications has not
    /// changed. Mirrors `cachedClaims()`, kept as its own cache rather than sharing
    /// one with claims: the two answer different questions at different call sites,
    /// and a caller of one must not pay for, or receive, the other's staleness window.
    static func cachedIdentitiesList() -> [Owner] {
        let live = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier))
        if live == cachedIdentityPIDs, !cachedIdentities.isEmpty { return cachedIdentities }
        return refreshIdentityCache()
    }

    @discardableResult
    static func refreshIdentityCache() -> [Owner] {
        let fresh = identities()
        cachedIdentities = fresh
        cachedIdentityPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier))
        return fresh
    }

    /// Refreshes the identity and on-bar claim caches from one Accessibility walk.
    ///
    /// App lifecycle notifications need both views of the same status items. Calling the two
    /// public refresh methods separately would repeat the measured ~0.9 second owner walk on the
    /// main actor. One snapshot keeps the caches coherent and makes refresh-only observation cheap
    /// enough to run after an app launches without moving any menu-bar item.
    @discardableResult
    static func refreshCaches() -> (identities: [Owner], claims: [Owner]) {
        let fresh = identities()
        let live = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier))
        cachedIdentities = fresh
        cachedIdentityPIDs = live
        cached = fresh.filter { $0.axLeftEdge > 0 }
        cachedPIDs = live
        return (fresh, cached)
    }

    private static var cachedIdentities: [Owner] = []
    private static var cachedIdentityPIDs: Set<pid_t> = []

    /// The best available name for ONE item, not for its owning application.
    ///
    /// The distinction matters most for Control Center, which owns six visible items on
    /// this machine. Using the application's name for each produced six rows all
    /// reading "Control Center", which is not a list, and threw away identity macOS was
    /// willing to hand over. Measured, via `AXDescription` on each child:
    ///
    ///     x2082  Audio and Video Controls
    ///     x2214  Now Playing
    ///     x2247  Wi-Fi, connected, 3 bars
    ///     x2285  Battery
    ///     x2361  Control Center, Microphone
    ///     x2403  Clock
    ///
    /// `AXTitle` was empty for every one of them, so description is the field that
    /// carries this, and it is already localised by the system.
    ///
    /// Falls back to the application name, then to the pid. A third-party app almost
    /// always owns exactly one item and usually exposes no description, so for those
    /// rows the application name is both correct and what a user expects to read.
    private static func itemName(of child: AXUIElement,
                                in app: NSRunningApplication) -> String {
        let appName = app.localizedName ?? "pid \(app.processIdentifier)"
        guard let description = attribute(child, kAXDescriptionAttribute as String) as? String
        else { return appName }

        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return appName }

        // A description that only restates the application adds nothing, so prefer the
        // application name in that case and keep one spelling of it across the list.
        return trimmed == appName ? appName : trimmed
    }

    /// How long any one application may take to answer an accessibility read.
    ///
    /// Deliberately short. See `claims()` for the measurements: the default has no
    /// useful ceiling and a handful of unresponsive processes dominated the whole
    /// walk. Raising this trades panel latency for nothing, since no application
    /// that owns a status item needed more than this to say so.
    static let messagingTimeout: Float = 0.05

    // MARK: - caching

    /// The last resolved claims, and the set of process ids they were resolved
    /// against.
    ///
    /// The walk costs about 0.96s even with the policy filter and the messaging
    /// timeout, and it is 96 percent of the whole panel refresh: the window-server
    /// passes cost 0.039s, the frontmost-app menu walk 0.001s, and Control Center's
    /// own extras 0.011s. So the walk cannot run synchronously on a panel open
    /// without the panel visibly hanging, and it does not need to: which
    /// applications own status items changes only when one launches or quits.
    private static var cached: [Owner] = []
    private static var cachedPIDs: Set<pid_t> = []

    /// Claims from cache when the set of running applications has not changed.
    ///
    /// Keyed on the PID SET rather than on a timestamp, because that is the thing
    /// that actually invalidates the answer. A time-based cache would either refresh
    /// when nothing had changed, paying 0.96s for an identical result, or serve a
    /// stale list after an app quit. Comparing pids is free next to the walk.
    ///
    /// Positions are NOT part of what this caches usefully: an item's x moves
    /// whenever the bar reflows, so a caller that needs current geometry must call
    /// `claims(force: true)`. The cache exists so a panel can render its rows
    /// immediately with names that are almost certainly right, then correct itself.
    static func cachedClaims() -> [Owner] {
        let live = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier))
        if live == cachedPIDs, !cached.isEmpty { return cached }
        return refreshCache()
    }

    /// Walks and stores. Returns the fresh list.
    @discardableResult
    static func refreshCache() -> [Owner] {
        let fresh = claims()
        cached = fresh
        cachedPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier))
        return fresh
    }

    /// Whatever was last resolved, without walking anything. Empty before the first
    /// walk completes, which a caller must treat as "not known yet" rather than as
    /// "nothing is claimed".
    static var lastKnownClaims: [Owner] { cached }

    /// The owner of the item drawn at `frame`, or nil when no app claims it.
    ///
    /// Matched on NEAREST left edge, deliberately NOT on containment. Containment
    /// looks like the obvious test and is off by one slot: an item's AX left edge
    /// sits about 1pt to the LEFT of its own window's `minX`, which places it
    /// inside the neighbouring window to the left. Measured across a full bar, that
    /// mislabelled every third-party item as the app next to it, which is worse
    /// than not labelling it at all because it looks right.
    ///
    /// The tolerance is 10pt because the offset is not constant: most items sit
    /// within 1 to 3pt of their window's left edge, while Control Center's own
    /// extras and a couple of others measured 7 to 8pt out.
    static func owner(of frame: CGRect, in claims: [Owner]) -> Owner? {
        let nearest = claims.min {
            abs($0.axLeftEdge - frame.minX) < abs($1.axLeftEdge - frame.minX)
        }
        guard let nearest, abs(nearest.axLeftEdge - frame.minX) <= 10 else { return nil }
        return nearest
    }

    /// Splits scanned items into those a running application claims and those none
    /// does.
    ///
    /// Lives here rather than beside either caller because `Probe` phase 4 and
    /// `BarDoctor.checkCoverage` both need exactly this split, and they had it twice.
    /// Duplicated logic across two surfaces is the specific failure this project
    /// keeps hitting: the same defect has already had to be fixed twice in two files
    /// on three separate occasions today, so a shared owner is worth the indirection.
    ///
    /// `@MainActor` because `owner(of:in:)` is. The split is otherwise pure once
    /// `claims` is resolved, so a `@MainActor` test can drive it with synthetic
    /// frames and no live accessibility tree.
    static func split(_ subjects: [ObservedItem], claims: [Owner])
        -> (resolved: [(item: ObservedItem, owner: Owner)], unresolved: [ObservedItem]) {
        var resolved: [(item: ObservedItem, owner: Owner)] = []
        var unresolved: [ObservedItem] = []
        for item in subjects {
            if let owner = owner(of: item.frame, in: claims) {
                resolved.append((item, owner))
            } else {
                unresolved.append(item)
            }
        }
        return (resolved, unresolved)
    }

    /// Coverage is about every real item Stow may need to open, including items
    /// currently tucked at a large negative x. Resolve against `identities`, not
    /// on-bar `claims`, and remove spacer mechanisms that are not user items.
    static func coverageSplit(subjects: [ObservedItem], identities: [Owner],
                              screenWidth: CGFloat, excluding seamWindows: Set<CGWindowID>)
        -> (resolved: [(item: ObservedItem, owner: Owner)], unresolved: [ObservedItem]) {
        let eligible = subjects.filter {
            !seamWindows.contains($0.windowNumber)
                && $0.frame.width > 0
                && $0.frame.width <= screenWidth
        }
        return split(eligible, claims: identities)
    }

    /// The zero-reveal summary, or nil when nothing resolved.
    ///
    /// Nil rather than a "0 of 0" string on purpose: printing a rate computed from
    /// zero measured items is the fabrication this whole area exists to avoid. An
    /// unresolved item is counted separately and never folded into either outcome,
    /// because it is neither a zero-reveal item nor a reveal-one item, it is
    /// unmeasured.
    ///
    /// Pure arithmetic, so `nonisolated`: the seam a unit test drives directly,
    /// independent of the AX walk that produced the counts.
    nonisolated static func coverageSummary(free: Int, resolved: Int,
                                            unresolved: Int) -> String? {
        guard resolved > 0 else { return nil }
        var detail = "\(free) of \(resolved) resolved item(s) open with zero reveal"
        if unresolved > 0 { detail += ", \(unresolved) unresolved" }
        return detail
    }

    // MARK: - AX plumbing

    /// Checked bridge to `AXUIElement`. Mirrors `PressActionProbe.asElement`: these
    /// values come out of another process's accessibility tree, so `as!` would trap
    /// on any type this project did not anticipate.
    private static func element(of value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success
        else { return nil }
        return result
    }

    /// Same checked-bridge pattern, for the `AXValue` boxes position and size arrive
    /// in. The type ID check confirms the box before `AXValueGetValue` is asked what
    /// shape is inside it.
    private static func axValue(of value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let boxed = axValue(of: attribute(element, kAXPositionAttribute as String))
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(boxed, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let boxed = axValue(of: attribute(element, kAXSizeAttribute as String))
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(boxed, .cgSize, &size) else { return nil }
        return size
    }
}
