import AppKit
import CoreGraphics

/// Enumerates menu bar status items via the window server.
///
/// This is the file the whole design rests on. `RevealCoordinator` needs an item's
/// WIDTH to know how far to shrink the spacer, and that item is, by construction,
/// currently pushed off the visible bar. If its frame cannot be read, reveal-one is
/// impossible and mirroring becomes mandatory. `Probe` exists to answer that.
enum BarScanner {

    /// Status items live at the status window level. Read from the API rather than
    /// hardcoding 25, so a future OS that renumbers levels does not silently return
    /// an empty scan.
    static var statusWindowLayer: Int {
        Int(CGWindowLevelForKey(.statusWindow))
    }

    struct ScanResult: Sendable {
        let items: [ObservedItem]
        /// True when at least one window reported `kCGWindowName`.
        ///
        /// Since macOS 10.15 that key is withheld without a Screen Recording grant,
        /// while geometry, pid and layer are still returned. So this doubles as a
        /// live check that Stow is getting what it needs WITHOUT that grant: if
        /// `items` is populated and this is false, the no-capture design is confirmed
        /// working rather than merely assumed.
        let sawWindowNames: Bool
        /// Everything the window server returned, before filtering. Reported by the
        /// probe so an empty result can be distinguished from a bad filter.
        let totalWindowsInspected: Int
    }

    /// Scan for status items whose frames intersect, or would intersect, the menu bar
    /// band of `menuBarRect`.
    ///
    /// - Important: the option set is `.optionAll`, NOT `.optionOnScreenOnly`, and
    ///   that is the single most important line in this file. `.optionOnScreenOnly`
    ///   filters out exactly the windows this design needs to measure, so using it
    ///   would make an engineer conclude that off-screen frames are unreadable when
    ///   in fact they were merely excluded from the query. That is a false negative
    ///   on the project's hard gate.
    static func scan(menuBarRect: CGRect) -> ScanResult {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return ScanResult(items: [], sawWindowNames: false, totalWindowsInspected: 0)
        }

        let layer = statusWindowLayer
        var sawNames = false
        var items: [ObservedItem] = []

        for info in raw {
            if info[kCGWindowName as String] as? String != nil { sawNames = true }

            guard let windowLayer = info[kCGWindowLayer as String] as? Int,
                  windowLayer == layer,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // Vertical band only. An item pushed off the bar keeps its Y and loses
            // its X, so filtering on Y finds the pushed ones while still rejecting
            // unrelated status-level windows further down the screen.
            //
            // Tolerance rather than equality: item heights are not uniform and a
            // strict match silently drops items.
            let sharesBand = abs(frame.minY - menuBarRect.minY) <= 4
                && frame.height <= menuBarRect.height + 4
            // Reject on zero HEIGHT, never on zero width.
            //
            // A zero-height window at bar level is junk (the window server returns a
            // few, e.g. a 0x0 Control Center placeholder). A zero-WIDTH one is the
            // opposite: it is a real item that kept its Y and lost its X extent,
            // which is precisely the `FAIL` signal this project's gate exists to
            // detect. Filtering on width would delete that evidence, and phase 3
            // would then see the pushed items simply vanish from the scan and report
            // INCONCLUSIVE instead of FAIL. Never restore a `width > 0` test here.
            guard sharesBand, frame.height > 0 else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            items.append(ObservedItem(
                windowNumber: number,
                ownerPID: pid,
                bundleID: app?.bundleIdentifier,
                ownerName: app?.localizedName
                    ?? (info[kCGWindowOwnerName as String] as? String)
                    ?? "pid \(pid)",
                frame: frame,
                isOnScreen: menuBarRect.intersects(frame)
            ))
        }

        // Right to left is the order macOS lays status items out, and the order the
        // sub-bar mirrors. Sorting by X descending therefore produces bar order
        // directly, with the deepest-tucked item last.
        items.sort { $0.frame.minX > $1.frame.minX }
        return ScanResult(items: items,
                          sawWindowNames: sawNames,
                          totalWindowsInspected: raw.count)
    }

    /// The window level the Window Server draws the menu bar itself at.
    ///
    /// Read from the API rather than hardcoding 24, for the same reason
    /// `statusWindowLayer` reads `.statusWindow` instead of hardcoding 25.
    static var mainMenuLayer: Int {
        Int(CGWindowLevelForKey(.mainMenuWindow))
    }

    /// The menu bar band for a screen, in Quartz global coordinates.
    ///
    /// `kCGWindowBounds` is top-left origin and AppKit is bottom-left, so this cannot
    /// just hand back `NSScreen.frame`.
    ///
    /// The height is MEASURED from the window server, not asked of AppKit, because
    /// every AppKit answer available here under-reports it and the band test then
    /// rejects every status item. Both of these were observed, on two displays:
    ///
    /// - 16-inch notched built-in: `NSStatusBar.system.thickness` returns the classic
    ///   22, `safeAreaInsets.top` returns 32, and the item windows are 33 tall.
    /// - Notchless 2560x1080 external: thickness returns 22, `safeAreaInsets.top`
    ///   returns 0, and the item windows are 30 tall.
    ///
    /// So a `max(thickness, safeAreaInsets.top)` of 22 on the external display could
    /// not reach 30 even with the band tolerance, and the probe aborted with "no
    /// status items matched" on a perfectly healthy bar. The Window Server's OWN menu
    /// bar window is the one source that agreed with the items on both displays: 33
    /// where they were 33, 30 where they were 30. Measure that.
    ///
    /// Falls back to the AppKit values when that window cannot be found, since a
    /// too-short band still finds the items whose height happens to fit, which beats
    /// returning nothing at all.
    @MainActor
    static func menuBarRect(for screen: NSScreen) -> CGRect {
        // Quartz Y grows downward from the top-left of the PRIMARY display, so a
        // screen's Quartz top edge is the primary's height minus this screen's
        // AppKit maxY.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let quartzTop = primaryHeight - screen.frame.maxY

        let fallback = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        return CGRect(x: screen.frame.minX, y: quartzTop,
                      width: screen.frame.width,
                      height: cachedBarHeight(quartzTop: quartzTop, screen: screen) ?? fallback)
    }

    /// `measuredBarHeight`, memoised per display.
    ///
    /// The measurement is a SECOND full window-list walk, and it was being run on every call to
    /// `menuBarRect`, which is the hottest primitive in this codebase: every `barItems()`,
    /// `positionableItems()` and `SpacerItem.measuredFrame()` goes through it, including inside all
    /// five polling loops. Measured with a harness over 287 windows: the walk is 5.6ms of a 15.3ms
    /// `positionableItems()`, so 36% of the primitive, and a best-case arrange with nothing to move
    /// paid it about nine times, roughly 0.11s of the 0.46s the arrange is meant to take. All of it
    /// re-deriving a value that changes only when the display configuration does.
    ///
    /// Keyed on the screen's frame rather than its name, exactly as `HideController` already keys
    /// its placement-floor cache. The key catches a reshape of THIS screen, since the measurement
    /// matches on that geometry and a resolution change produces a different key.
    ///
    /// The key alone is NOT sufficient, which is why the invalidation exists rather than being
    /// belt-and-braces. `quartzTop` is derived as the PRIMARY display's height minus this screen's
    /// maxY, so changing the primary's resolution moves a secondary screen's Quartz origin while
    /// leaving that secondary's own frame, and therefore its key, untouched. The
    /// `didChangeScreenParameters` observer in `AppDelegate` is what covers that case.
    @MainActor
    private static func cachedBarHeight(quartzTop: CGFloat, screen: NSScreen) -> CGFloat? {
        // The frame as a plain string key. `NSStringFromRect` is the AppKit spelling; it is stable
        // for a given frame and needs no Hashable conformance on CGRect.
        let key = NSStringFromRect(screen.frame)
        if let hit = barHeightByDisplay[key] { return hit }
        guard let measured = measuredBarHeight(quartzTop: quartzTop,
                                               screenMinX: screen.frame.minX,
                                               screenWidth: screen.frame.width)
        else { return nil }
        barHeightByDisplay[key] = measured
        return measured
    }

    @MainActor private static var barHeightByDisplay: [String: CGFloat] = [:]

    /// Drops every memoised bar height, for a display reconfiguration.
    ///
    /// Called from the app's `didChangeScreenParametersNotification` observer. Wholesale rather
    /// than per screen: a reconfiguration can add, remove or reshape displays, and re-measuring one
    /// height costs 5.6ms against the risk of serving a stale band that silently drops every item.
    @MainActor
    static func forgetMeasuredBarHeights() {
        barHeightByDisplay.removeAll()
    }

    /// Height of the Window Server's menu bar window for one screen, or nil.
    ///
    /// Matched on THIS screen's geometry rather than taking the first candidate,
    /// because a multi-display setup has one such window per display and picking the
    /// wrong one would measure another screen's bar.
    private static func measuredBarHeight(quartzTop: CGFloat,
                                          screenMinX: CGFloat,
                                          screenWidth: CGFloat) -> CGFloat? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        let layer = mainMenuLayer
        for info in raw {
            guard let windowLayer = info[kCGWindowLayer as String] as? Int,
                  windowLayer == layer,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // Spans this screen's full width at this screen's top edge. The width
            // test is what distinguishes the bar from anything else the window
            // server happens to draw at this level.
            guard abs(frame.minY - quartzTop) <= 2,
                  abs(frame.minX - screenMinX) <= 2,
                  abs(frame.width - screenWidth) <= 2,
                  frame.height > 0
            else { continue }

            return frame.height
        }
        return nil
    }

    /// Width of the notch dead zone on this screen, or zero when notchless.
    ///
    /// `auxiliaryTopLeftArea` is nil on a display without a notch, which is the clean
    /// signal. When present, the gap between the left and right auxiliary areas is
    /// the unusable span.
    @MainActor
    static func notchWidth(for screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, right.minX - left.maxX)
    }
}
