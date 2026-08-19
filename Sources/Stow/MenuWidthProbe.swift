import AppKit
import ApplicationServices
import CoreGraphics

/// Measures the two `BarBudget` fields `Probe` currently reports as zero: how much
/// of the menu bar the FRONTMOST app's own menus occupy, and how much the system
/// reserves for the clock, Control Center and Siri.
///
/// Both are optionals, deliberately. Neither field's true value is ever zero on a
/// real Mac, since Control Center's own icon is never absent, so a zero here would
/// be indistinguishable from "measured and genuinely found nothing." Nil is the
/// honest signal for "could not measure," and it is on the caller, `Probe` and
/// later the live panel, to decide how that differs from a measured zero.
@MainActor
final class MenuWidthProbe {

    /// Width the FRONTMOST app's own menu titles occupy right now. Nil when
    /// Accessibility is not granted, or the app's `AXMenuBar` could not be read.
    private(set) var frontmostAppMenuWidth: CGFloat?
    /// Width the system reserves for the clock, Control Center's own icon and
    /// Siri. Nil when Control Center's items could not be told apart from
    /// third-party ones hosted alongside them; see `measureSystemTrailingWidth`
    /// for the reason that split is not always possible.
    private(set) var systemTrailingWidth: CGFloat?

    /// The frontmost-app watch.
    ///
    /// A `Task` rather than an observer token on purpose. `deinit` on a
    /// `@MainActor` class is nonisolated, so it may only touch Sendable stored
    /// properties, and `NSObjectProtocol` is not one. `Task` is, so cancelling it
    /// here is legal where removing an observer token was not. The compiler's
    /// suggested `@preconcurrency` would have silenced that rather than fixed it.
    private var watch: Task<Void, Never>?

    init() {
        recompute()
        // The left side of the bar belongs to whichever app is frontmost: Finder
        // gives five short menu titles, Xcode gives nine, and the same reveal fits
        // with one in front and clips with the other, with no action from the
        // user. Recomputing on every frontmost-app change is what lets `.crowded`
        // be a DETECTED condition rather than a number measured once at launch and
        // left stale for the rest of the session.
        //
        // Register on `NSWorkspace.shared.notificationCenter`, NOT on
        // `NotificationCenter.default`. AppKit's NSWorkspace.h is explicit: "All
        // notifications in this header file must be registered on this
        // notification center. If you register on other notification centers, you
        // will not receive the notifications." An earlier version of this file used
        // the default center, which compiled, ran, and silently never fired once,
        // leaving the budget frozen at its launch value for the whole session.
        // That is the exact staleness this observer exists to prevent.
        watch = Task { @MainActor [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            let changes = center.notifications(
                named: NSWorkspace.didActivateApplicationNotification)
            for await _ in changes {
                guard let self else { return }
                self.recompute()
            }
        }
    }

    deinit {
        watch?.cancel()
    }

    /// Re-measures both fields against whatever app is frontmost right now.
    func recompute() {
        frontmostAppMenuWidth = Self.measureFrontmostAppMenuWidth()
        systemTrailingWidth = Self.measureSystemTrailingWidth()
    }

    // MARK: - frontmost app menu width

    /// Width of the FRONTMOST app's own menu titles (File, Edit, View, ...),
    /// summed from its `AXMenuBar`.
    ///
    /// Needs the Accessibility grant, like everything else that walks an AX tree
    /// in this app. Reporting zero without the grant would say "this app has no
    /// menus," which is never true and would silently overstate
    /// `BarBudget.usable`. Nil says the honest thing instead: not measurable right
    /// now.
    static func measureFrontmostAppMenuWidth() -> CGFloat? {
        guard PressActionProbe.isTrusted else { return nil }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        return menuBarWidth(forPID: pid)
    }

    /// Walks one app's `AXMenuBar` and sums its children's widths.
    ///
    /// `AXMenuBar` is the app's OWN menus. `PressActionProbe` walks
    /// `AXExtrasMenuBar` instead, which is the status-item tray on the opposite
    /// end of the bar. The two attributes are one letter apart and would sum the
    /// wrong half of the bar entirely if swapped.
    static func menuBarWidth(forPID pid: pid_t) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        // Cap how long this application may take to answer. Without a cap a
        // single unresponsive process blocks the whole walk: measured at about
        // 1.5s each for five WebKit renderers in `BarItemOwners.claims()`. The
        // shared constant keeps every accessibility entry point in this package
        // on the same ceiling.
        AXUIElementSetMessagingTimeout(app, BarItemOwners.messagingTimeout)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString,
                                             &menuBarRef) == .success,
              let menuBar = asElement(menuBarRef) else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString,
                                             &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        return sumMeasuredWidths(children.map(width(of:)))
    }

    /// One menu item's width via its `AXSize`. Nil when the attribute is missing,
    /// or is not the `CGSize`-shaped value the API documents it as.
    static func width(of element: AXUIElement) -> CGFloat? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                             &sizeRef) == .success,
              let axValue = asAXValue(sizeRef) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size.width
    }

    /// Sums a list of per-item measurements, keeping "no items" distinct from
    /// "items existed but none could be measured."
    ///
    /// An empty list is a real zero: an app that genuinely has no menu items
    /// occupies no width, and reporting that as unmeasurable would be a lie in the
    /// other direction from the one this file exists to avoid. But if items exist
    /// and every one of them failed to report a size, that is not "zero width," it
    /// is "the AX call did not work," which is a real state, seen in practice
    /// while an app is mid-relaunch. Between those two, an item that DID measure
    /// silently outweighs one that did not: a stray unmeasurable separator should
    /// not blank out an otherwise good reading of nine real menu titles.
    ///
    /// `nonisolated` because it is pure arithmetic over its argument and touches no
    /// actor state. Without it the method inherits this class's `@MainActor` and a
    /// synchronous test cannot call it at all. This is plain `nonisolated`, which
    /// the compiler verifies, not `nonisolated(unsafe)`, which would merely assert.
    nonisolated static func sumMeasuredWidths(_ widths: [CGFloat?]) -> CGFloat? {
        guard !widths.isEmpty else { return 0 }
        let measured = widths.compactMap { $0 }
        guard !measured.isEmpty else { return nil }
        return measured.reduce(0, +)
    }

    // MARK: - system trailing width

    /// Bundle identifier of the process that hosts the system's own status items,
    /// and, per the discriminator problem documented on
    /// `measureSystemTrailingWidth`, everyone else's too.
    private static let controlCenterBundleID = "com.apple.controlcenter"

    /// Width the system reserves for the clock, Control Center's own icon and
    /// Siri, read from the window server rather than assumed.
    ///
    /// The obvious approach, "sum every status-level window owned by
    /// `com.apple.controlcenter`," is WRONG on this OS and would silently overstate
    /// the system's share of the bar. Measured directly on this machine: every
    /// third-party status item, not only Apple's own, is ALSO hosted inside the
    /// Control Center process and reports that same bundle id, indistinguishable
    /// from Clock or WiFi by owner alone. Summing blind would count the user's own
    /// menu bar items as "system," inflating this field by however many
    /// third-party items happen to be running that day, and `BarBudget.usable`
    /// would then UNDERSTATE real capacity for a reason nobody could see from the
    /// arithmetic alone.
    ///
    /// The discriminator that DOES hold, found by inspecting Control Center's own
    /// accessibility tree rather than guessing: Control Center tags its own
    /// hosted extras with an `AXIdentifier` of the form `com.apple.menuextra.*` on
    /// its `AXExtrasMenuBar` children (seen: battery, clock, wifi, controlcenter,
    /// now-playing, sound). Third-party items hosted alongside them report a nil
    /// identifier, because that field is Control Center's own bookkeeping and not
    /// one a third-party status item gets to set. So this walks Control Center's
    /// AX tree for identifier and X position, then matches each identified system
    /// item to the window-server frame containing that position and sums THOSE
    /// frames' widths, so the number handed to `BarBudget` is a real window width
    /// like every other field in it, not an AX-reported size that measured 16pt
    /// narrower than the window frame when the two were checked side by side.
    ///
    /// Nil, never a guess, at every step that cannot be confirmed: no Accessibility
    /// grant, Control Center is not running, its AX tree yields no identified
    /// system item, or none of those items can be matched back to a window. A
    /// wrong number here is the failure mode this design exists to avoid.
    static func measureSystemTrailingWidth() -> CGFloat? {
        guard PressActionProbe.isTrusted else { return nil }
        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == controlCenterBundleID
        })?.processIdentifier else { return nil }

        let systemXPositions = systemExtraXPositions(forPID: pid)
        guard !systemXPositions.isEmpty else { return nil }

        guard let screen = NSScreen.main else { return nil }
        let barRect = BarScanner.menuBarRect(for: screen)
        let candidateFrames = BarScanner.scan(menuBarRect: barRect).items
            .filter { $0.bundleID == controlCenterBundleID }
            .map(\.frame)
        guard !candidateFrames.isEmpty else { return nil }

        let widths = matchedWidths(systemXPositions: systemXPositions,
                                    candidateFrames: candidateFrames)
        guard !widths.isEmpty else { return nil }
        return widths.reduce(0, +)
    }

    /// Apple's own status items, named, for a caller that needs to label rows
    /// rather than sum widths.
    ///
    /// Empty when Accessibility is not granted or Control Center is not running,
    /// which a caller must read as "nothing could be identified" and NOT as
    /// "nothing is a system item." The difference matters: treating an empty result
    /// as proof of absence would relabel Apple's own extras as unidentified, and
    /// treating a failure as success would do the reverse.
    static func identifiedSystemExtras() -> [SystemExtra] {
        guard PressActionProbe.isTrusted else { return [] }
        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == controlCenterBundleID
        })?.processIdentifier else { return [] }
        return systemExtras(forPID: pid)
    }

    /// One of Control Center's OWN status items: where it sits, and what it is.
    ///
    /// The name comes from `AXDescription`, which is the only human-readable
    /// string these elements carry. `AXTitle` is empty on every one of them, so
    /// reading title would return blanks for all six.
    struct SystemExtra: Sendable {
        let x: CGFloat
        let name: String
    }

    /// Control Center's OWN status items: the ones whose `AXIdentifier` starts with
    /// `com.apple.`, per the discriminator documented above. Empty when the walk
    /// fails for any reason, which the caller treats as "could not measure," never
    /// as "zero system items," since Control Center's own icon is always present.
    ///
    /// This is also the ONLY way to name anything in the bar on this OS, and it
    /// names only Apple's own extras. Measured on macOS 26.6.1: the six system
    /// items carry an identifier plus a real `AXDescription` (Battery, Clock,
    /// Wi-Fi, Control Center, Now Playing, Sound), while every third-party item
    /// hosted alongside them reports a nil identifier, a nil title, a nil
    /// description AND an x position of 0. So a third-party item cannot be named,
    /// positioned, or even counted from this tree. Callers must not present an
    /// unidentified item as a system one; that mislabels the user's own items.
    static func systemExtras(forPID pid: pid_t) -> [SystemExtra] {
        let app = AXUIElementCreateApplication(pid)
        // Cap how long this application may take to answer. Without a cap a
        // single unresponsive process blocks the whole walk: measured at about
        // 1.5s each for five WebKit renderers in `BarItemOwners.claims()`. The
        // shared constant keeps every accessibility entry point in this package
        // on the same ceiling.
        AXUIElementSetMessagingTimeout(app, BarItemOwners.messagingTimeout)

        // `AXExtrasMenuBar`, not `AXMenuBar`: this is the status-item tray, the
        // same attribute `PressActionProbe` reads, walked here on Control Center's
        // OWN process rather than an arbitrary status item's owner.
        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString,
                                             &extrasRef) == .success,
              let extras = asElement(extrasRef) else { return [] }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString,
                                             &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }

        var found: [SystemExtra] = []
        for child in children {
            var idRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString,
                                          &idRef)
            guard (idRef as? String)?.hasPrefix("com.apple.") == true else { continue }

            var posRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                                 &posRef) == .success,
                  let posValue = asAXValue(posRef) else { continue }
            var point = CGPoint.zero
            guard AXValueGetValue(posValue, .cgPoint, &point) else { continue }

            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString,
                                          &descRef)
            let name = (descRef as? String) ?? "System item"
            found.append(SystemExtra(x: point.x, name: name))
        }
        return found
    }

    /// Just the X positions, for the width arithmetic that does not care about names.
    private static func systemExtraXPositions(forPID pid: pid_t) -> [CGFloat] {
        systemExtras(forPID: pid).map(\.x)
    }

    /// Pairs each system item's AX position to the window-server frame that
    /// contains it, and returns THOSE frames' widths.
    ///
    /// Pure and testable on purpose: no AX, no window server, just geometry.
    /// Containment rather than equality, because the AX position sits INSIDE the
    /// window frame rather than exactly at its origin. Measured on this machine:
    /// the window frame runs about 16pt wider than the AX-reported size, which
    /// reads as hit-target padding around the visible glyph, and an equality test
    /// would have matched nothing at all.
    nonisolated static func matchedWidths(systemXPositions: [CGFloat],
                                          candidateFrames: [CGRect]) -> [CGFloat] {
        systemXPositions.compactMap { x in
            candidateFrames.first { $0.minX <= x && x <= $0.maxX }?.width
        }
    }

    // MARK: - CF bridging

    /// Bridges a `CFTypeRef` to `AXUIElement` only when the runtime type genuinely
    /// matches. Mirrors `PressActionProbe.asElement`: these values come out of
    /// another process's AX tree, so `as!` would trap on any type this project did
    /// not anticipate, and a checked type ID turns that crash into a clean nil.
    private static func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Same checked-bridge pattern as `asElement`, for the `AXValue` boxes that
    /// `AXSize` and `AXPosition` come back as. `AXValueGetValue` still has to be
    /// asked what shape is inside; the type ID check only confirms the box itself
    /// is genuinely an `AXValue` before that.
    private static func asAXValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
