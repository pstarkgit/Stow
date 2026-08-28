import AppKit
import ApplicationServices

/// Decides, per item, whether Stow can open it WITHOUT touching the spacer.
///
/// The cheap path first: if a status item exposes `kAXPressAction`, pressing it opens
/// its menu with zero reveal. No spacer change, no relayout wait, no timing window,
/// no plus-one delta. On a bar as full as the one this app was written for, every
/// item that answers here costs nothing at all, and the expensive dance in
/// `RevealCoordinator` becomes the exception rather than the rule.
///
/// Coverage will be inconsistent. Most status items are custom `NSView`s that expose
/// no action, so this is an optimisation to measure rather than a mechanism to rely
/// on. `Stow --probe` reports the real hit rate across the items actually in the bar,
/// and the Doctor surfaces it afterwards, because that number determines how often
/// the risky path runs.
@MainActor
final class PressActionProbe {

    /// Cached per bundle ID, not per window: an app's status item exposes the same
    /// actions across relaunches, and window numbers do not survive them.
    private var cache: [String: RevealPath] = [:]

    /// Whether Accessibility has been granted.
    ///
    /// Without it every AX call returns `.apiDisabled` and both paths are dead, since
    /// `revealOne` also needs AX to synthesize its click. Reported as `.blocked`
    /// rather than retried, per the family rule about being honest when the app
    /// cannot do its job.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once. Safe to call repeatedly; macOS shows the sheet only when the app
    /// is untrusted and has not been denied in this session.
    static func requestTrust() {
        // The SDK exposes `kAXTrustedCheckOptionPrompt` as a mutable global, which
        // Swift 6 refuses to read as shared mutable state. Its value is the stable,
        // documented key string, so spell the key instead of reaching for the symbol.
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// The cheapest available path for an item.
    func path(for item: ObservedItem) -> RevealPath {
        guard Self.isTrusted else { return .unavailable }
        if let key = item.bundleID, let cached = cache[key] { return cached }

        let resolved = Self.probe(pid: item.ownerPID)
        if let key = item.bundleID { cache[key] = resolved }
        return resolved
    }

    /// Bridge a `CFTypeRef` to `AXUIElement` only when the runtime type genuinely
    /// matches.
    ///
    /// `as! AXUIElement?` traps on any other CF type, and these values come out of
    /// another process's AX tree, so their type is not ours to assume. Checking the
    /// type ID first turns a crash into the `.revealOne` fallback the callers already
    /// handle.
    nonisolated private static func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Walk the app's AX tree looking for a menu bar item that answers to a press.
    ///
    /// `AXUIElementCopyActionNames` on the extras menu bar's children is the honest
    /// question: "will pressing this do something." Asking the application element
    /// directly would not, because the action lives on the item, not the app.
    static func probe(pid: pid_t) -> RevealPath {
        let app = AXUIElementCreateApplication(pid)
        // Cap how long this application may take to answer. Without a cap a
        // single unresponsive process blocks the whole walk: measured at about
        // 1.5s each for five WebKit renderers in `BarItemOwners.claims()`. The
        // shared constant keeps every accessibility entry point in this package
        // on the same ceiling.
        AXUIElementSetMessagingTimeout(app, BarItemOwners.messagingTimeout)

        // `AXExtrasMenuBar` is where status items live. A plain `AXMenuBar` is the
        // app's own menus and is not what we want to press.
        var extrasRef: CFTypeRef?
        let attr = "AXExtrasMenuBar" as CFString
        guard AXUIElementCopyAttributeValue(app, attr, &extrasRef) == .success,
              let extras = asElement(extrasRef) else {
            return .revealOne
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return .revealOne
        }

        for child in children {
            var namesRef: CFArray?
            guard AXUIElementCopyActionNames(child, &namesRef) == .success,
                  let names = namesRef as? [String] else { continue }
            if names.contains(kAXPressAction as String) { return .pressAction }
        }
        return .revealOne
    }

    /// Press the item and report whether its menu actually opened.
    ///
    /// Two things here are not obvious, and both were found by pressing a real
    /// third-party item (1Password) and watching what happened.
    ///
    /// First, the timeout must be GENEROUS, not the short walk timeout. A press
    /// blocks while the target app builds and shows its menu, so the 50ms cap that is
    /// correct for a bulk attribute read guarantees the press reports failure. That
    /// cap was briefly applied here and was wrong: it is right for asking 90 apps a
    /// cheap question, wrong for asking one app to do something.
    ///
    /// Second, and worse, `AXUIElementPerformAction` returns `kAXErrorCannotComplete`
    /// (-25204) for a press that DID open the menu. Measured: the return was -25204
    /// while the count of windows at pop-up-menu level went from 15 to 16. So a
    /// `== .success` test reports failure on a success, and the caller then falls
    /// through to the expensive reveal path for an item that had already opened. That
    /// is the worst possible outcome on the one path that works without any spacer
    /// positioning at all.
    ///
    /// So success is decided by OBSERVING the menu, not by the return code: count the
    /// windows above bar level, press, and see whether one appeared. That is the same
    /// discipline the rest of this package uses for the window server, where the
    /// setter's own answer is never taken as proof the thing happened.
    /// `nonisolated` and therefore callable off the main actor, which is the whole
    /// point. Measured on a real item: the press blocks for 1.764s, because the menu
    /// it opens is modal and the app never gets round to answering, so the call sits
    /// until the messaging timeout expires. On the main actor that is a two-second
    /// frozen UI for an action whose visible effect already happened in the first few
    /// milliseconds. Nothing here touches AppKit view state, so nothing here needs
    /// main-actor isolation.
    nonisolated static func press(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, pressTimeout)

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString,
                                            &extrasRef) == .success,
              let extras = asElement(extrasRef) else { return false }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            var namesRef: CFArray?
            guard AXUIElementCopyActionNames(child, &namesRef) == .success,
                  let names = namesRef as? [String],
                  names.contains(kAXPressAction as String) else { continue }

            let before = menuLevelWindowCount()
            let result = AXUIElementPerformAction(child, kAXPressAction as CFString)
            // A menu takes a moment to appear, and this is a deliberate user-initiated
            // action rather than a poll, so a short wait here is honest rather than a
            // guess: without it the count is read before the window server has the
            // menu, and a genuine success reads as a failure.
            Thread.sleep(forTimeInterval: 0.25)
            if menuLevelWindowCount() > before { return true }
            // No menu appeared. Only now does the return code matter, and only to
            // distinguish "the app refused" from "the app never answered".
            return result == .success
        }
        return false
    }

    /// Hidden sentinels must never be pressed. ACME reports x=-1 while tucked; pressing
    /// that element opens its menu but macOS clamps the menu to the far-left screen edge.
    nonisolated static func positionIsVisible(_ x: CGFloat) -> Bool { x > 0 }

    /// Waits for AX to publish the WindowServer move before opening the target menu.
    /// Replaces the fixed 120ms delay that regularly raced ACME's stale x=-1 position.
    nonisolated static func waitForVisiblePressItem(pid: pid_t,
                                                    timeout: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if hasVisiblePressItem(pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
    }

    nonisolated private static func asAXValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    nonisolated private static func hasVisiblePressItem(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString,
                                            &extrasRef) == .success,
              let extras = asElement(extrasRef) else { return false }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }

        for child in children {
            var namesRef: CFArray?
            guard AXUIElementCopyActionNames(child, &namesRef) == .success,
                  let names = namesRef as? [String],
                  names.contains(kAXPressAction as String) else { continue }
            var positionRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                                &positionRef) == .success,
                  let value = asAXValue(positionRef) else { continue }
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else { continue }
            if positionIsVisible(point.x) { return true }
        }
        return false
    }

    /// How long a single deliberate press may take. Far longer than the walk timeout,
    /// because the target app is building a menu rather than answering a field read.
    nonisolated static let pressTimeout: Float = 2.0

    /// Windows at or above the pop-up-menu level, which is where a status item's menu
    /// appears. Counting them is how a press is confirmed, since the press API's own
    /// return value cannot be trusted for this.
    nonisolated private static func menuLevelWindowCount() -> Int {
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        return raw.reduce(into: 0) { count, info in
            if let layer = info[kCGWindowLayer as String] as? Int, layer >= popUpLevel {
                count += 1
            }
        }
    }
}
