import AppKit
import CoreGraphics

/// The single seam between apps that stay on the bar and apps placed in Stow.
///
/// Owns no policy. It is a length, a seam, and a click target: deciding WHEN
/// to expand or collapse it, and by how much, belongs to whatever subsystem
/// reads item widths off the window server, not to this file. Consistent with
/// that, the button's click handling is deliberately left unwired here: real
/// behaviour depends on subsystems this stage does not build, and leaving
/// `target`/`action` nil means a click today does nothing rather than
/// crashing or silently misbehaving.
@MainActor
final class SpacerItem {

    /// Width at rest, in points, requested.
    ///
    /// 1, and the number is nearly irrelevant: macOS adds about 16pt of its own padding
    /// to any status item, so this measures ~17pt on the bar. Measured across a sweep:
    ///
    ///     requested 1pt  -> 17pt      requested 6pt  -> 22pt
    ///     requested 2pt  -> 18pt      requested 10pt -> 26pt
    ///     requested 4pt  -> 20pt
    ///
    /// So 17pt is the floor for ANY second item, and asking for less than that buys
    /// nothing. Design §4 asked for 10pt and called the footprint "the point"; that was
    /// written before the padding was measured, and 10pt was never achievable.
    ///
    /// `nonisolated` because it is a plain Sendable constant with no actor state behind
    /// it, so the pure arithmetic in `clampedLength` can read it without hopping to the
    /// main actor. Plain `nonisolated`, verified by the compiler, not
    /// `nonisolated(unsafe)`, which would only assert it.
    nonisolated static let restingLength: CGFloat = 1

    /// A named boundary is retained for preference compatibility and diagnostic call sites,
    /// but there is intentionally only one case.
    enum Boundary: String, CaseIterable, Sendable {
        /// Between apps that remain visible and apps placed in Stow.
        case tucked

        /// A stable identity string AppKit uses to persist this seam's position across
        /// launches. Without it macOS has nothing to key placement to and the item
        /// returns leftmost every relaunch, with nothing to its left to push.
        ///
        /// The tucked seam keeps the original "RailSpacer" name deliberately: an existing
        /// install already has a placement stored under it, and renaming would throw that
        /// away and drop the seam back to leftmost on the next launch.
        var autosaveIdentity: String {
            "RailSpacer"
        }

        /// Where this seam sits by default, as a distance from the right edge.
        ///
        /// Larger than `HideController.tokenOffsetFromRightEdge`, which keeps Stow's own
        /// token outside the seam so a hide never removes the control that undoes it.
        var defaultOffsetFromRightEdge: Int {
            8
        }
    }

    /// Which boundary this instance is. There is one case; retaining it keeps the existing
    /// placement preference stable across upgrades.
    let boundary: Boundary

    /// The `UserDefaults` key AppKit reads to decide where this item lands.
    ///
    /// This key is the whole reason Stow does not need a manual drag. Design §15 assumed
    /// placement was the user's job: "a freshly created status item lands leftmost and
    /// needs one manual drag to reach its working spot." That was half-right and the wrong
    /// half mattered. A fresh item does land leftmost, but placement is not drag-only: it
    /// is this preference, and writing it before the item is created places the item.
    ///
    /// Measured on a 2560pt bar, writing this key and relaunching:
    ///
    ///     value 100  ->  item at x2318   (right of every third-party item)
    ///     value 500  ->  item at x1865
    ///     value 900  ->  item at x1865   (clamped, already leftmost)
    ///
    /// So the value is a distance from the RIGHT edge, smaller is further right, and the
    /// useful range is bounded by the bar's own occupancy rather than by the number. This
    /// matters because a seam can only push what is to its LEFT: a seam that lands
    /// leftmost pushes nothing, which is precisely why expanding one moved zero of eight
    /// third-party items before this was understood.
    ///
    /// Synthetic drags are not an alternative. A synthesised Command-drag of a status item
    /// was measured leaving the item exactly where it started, so placement cannot be
    /// automated by pretending to be a user; it has to be this preference.
    static func placementKey(for boundary: Boundary) -> String {
        "NSStatusItem Preferred Position \(boundary.autosaveIdentity)"
    }

    /// Copies Airlock's saved seam positions into Stow's preference domain once.
    ///
    /// The autosave identities intentionally stay unchanged because AppKit keys
    /// placement by those strings. The bundle-id rename moves the preferences to
    /// a new domain, so the values still need this explicit bridge.
    static func migrateLegacyPlacementsIfNeeded() {
        guard let legacy = UserDefaults(suiteName: "dev.starkpat.airlock") else { return }
        for boundary in Boundary.allCases {
            let key = placementKey(for: boundary)
            guard UserDefaults.standard.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key) else { continue }
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// Places a seam at its default slot.
    ///
    /// MUST be called before the item is created: AppKit reads the placement preference
    /// when the item is made, so writing it afterwards has no effect until the next launch.
    static func place(_ boundary: Boundary, offsetFromRightEdge: Int? = nil) {
        UserDefaults.standard.set(offsetFromRightEdge ?? boundary.defaultOffsetFromRightEdge,
                                  forKey: placementKey(for: boundary))
    }

    /// The placement currently recorded for a boundary, or nil when never placed.
    static func recordedPlacement(for boundary: Boundary) -> Int? {
        UserDefaults.standard.object(forKey: placementKey(for: boundary)) as? Int
    }

    /// The one and only status item this app ever creates at a time. Kept as a strong
    /// reference for the lifetime of this object; letting it fall would drop the item
    /// from the bar with no warning to the user.
    ///
    /// `var` because moving the seam means replacing it: a status item's placement is
    /// read at creation, so the only way to move one is to destroy it and make
    /// another. See `reposition(placement:length:)`.
    private var item: NSStatusItem

    /// Window numbers the window server reported BEFORE this item existed, kept for the `--seam`
    /// diagnostic ONLY.
    ///
    /// `measuredFrame()` no longer consumes this. It used to diff a fresh scan against this set to
    /// pick out which window was ours, and that raced every other app's items at launch: measured,
    /// Stow's real windows were 70228, 70230 and 70232 while the seam resolved to 70231, a window
    /// created and destroyed by something else in between. The identity now comes from our own
    /// `button.window.frame`, at `measuredFrame()` below.
    ///
    /// The set is still live, so it is not orphaned state: `windowCountBeforeCreation`,
    /// `wasPresentBeforeCreation` and `unrecognisedItemCount` all read it, and `--seam` prints them.
    /// The original doc follows, describing what it was for.
    ///
    /// snapshotted once at init. `measuredFrame()` diffs a fresh scan against
    /// this set to pick out which window is ours, the same technique
    /// `Probe`'s phase 3 uses and for the same reason: on this OS every status
    /// item, including one this process just created, is attributed to the
    /// Control Center process, so a PID filter can never tell our own item
    /// apart from anyone else's.
    private var windowNumbersBeforeCreation: Set<CGWindowID>

    /// The window number of our own item, RE-RESOLVED on every successful `measuredFrame()` and
    /// cleared by `reposition`.
    ///
    /// Not "cached from then on", which is what this said and what made a stale value permanent: a
    /// wrong resolution at launch survived forever, and because the cached branch returned nil for
    /// the frame while this property still handed out the number, an arrange failed every move for
    /// a seam plainly sitting on the bar. Re-deriving per call is what makes that self-correcting.
    private var resolvedWindowNumber: CGWindowID?

    /// The seam's own window number once resolved, so a list of bar items can EXCLUDE
    /// it.
    ///
    /// Needed because Stow owns two items, its token and this seam, and both resolve
    /// through `BarItemOwners` to the name "Stow". An Arrange list that does not
    /// exclude the seam shows Stow twice and offers to cut at the cut, which is the
    /// duplicate row the pane was reported showing.
    var windowNumber: CGWindowID? { resolvedWindowNumber }

    /// - Parameters:
    ///   - boundary: the single Stow boundary.
    ///   - persistPlacement: whether to set `autosaveName`, so macOS remembers where the
    ///     seam sits. TRUE for the real app, which needs that placement to survive a
    ///     relaunch. FALSE for a short-lived diagnostic such as `--seam`, whose throwaway
    ///     item would otherwise write its own position over the real placement.
    init(boundary: Boundary = .tucked,
         state: BarState = .tidy,
         persistPlacement: Bool = true) {
        self.boundary = boundary
        self.persistPlacement = persistPlacement
        // A private identity for a non-persisting seam, so it can still be PLACED without
        // writing the shared preference. Placement is read from a preference keyed to the
        // autosave name at creation time, so a seam with no name at all cannot be positioned;
        // giving it a throwaway name keeps that ability without touching the real key.
        privateIdentity = persistPlacement
            ? boundary.autosaveIdentity
            : "\(boundary.autosaveIdentity)-probe-\(ProcessInfo.processInfo.processIdentifier)"
        currentPlacement = boundary.defaultOffsetFromRightEdge
        windowNumbersBeforeCreation = Self.currentWindowNumbers()
        item = NSStatusBar.system.statusItem(withLength: Self.restingLength)
        if persistPlacement {
            item.autosaveName = boundary.autosaveIdentity
        }
        paintedState = state
        Self.paint(item, for: state)
    }

    /// Whether this seam owns the shared placement preference for its boundary.
    ///
    /// Stored, not merely an initialiser argument, because `reposition` needs it too. It did
    /// not have it, and the consequence was not cosmetic: `reposition` set the shared
    /// `autosaveName` and wrote the shared placement key unconditionally, so a diagnostic
    /// created with `persistPlacement: false` silently took over the live app's seam identity
    /// the moment it repositioned. Measured while the app was running: a probe seam sent to a
    /// slot predicted at x1516 landed at x-3900, because two processes were contending for one
    /// autosave name, and it overwrote the user's real saved placement on the way out.
    private let persistPlacement: Bool

    /// The autosave name this instance actually uses: the shared one when persisting, a
    /// process-scoped throwaway otherwise.
    private let privateIdentity: String

    /// The state the seam is currently painted for, remembered so a replacement item
    /// created by `reposition(placement:length:)` keeps the palette rather than
    /// silently reverting to whatever the initialiser was first called with.
    private var paintedState: BarState

    /// The placement value this seam was last created with, so a caller searching for
    /// a slot can tell whether it already sits where it wants to be.
    private(set) var currentPlacement: Int

    /// Moves the seam to a different slot, and reports where it landed.
    ///
    /// A status item cannot be moved in place. Its position is read from the
    /// placement preference at CREATION time, so changing where it sits means
    /// destroying the item, writing the new preference, and making a new one. That is
    /// what this does, and it is verified: sweeping the preference this way moved a
    /// real item across six distinct slots between x1810 and x2323.
    ///
    /// - Parameter length: the width the NEW item must start at. Required, not
    ///   defaulted, because a recreated seam starts at its resting width, and a move
    ///   performed while the bar is hidden would otherwise return every hidden item
    ///   to the bar as a side effect of repositioning.
    /// - Returns: the seam's measured left edge after the move, or nil when the new
    ///   item never reached the window server.
    func reposition(placement: Int, length: CGFloat) -> CGFloat? {
        NSStatusBar.system.removeStatusItem(item)

        // Write the preference under THIS seam's own identity, which is the shared one only
        // when this seam persists. A non-persisting seam must be positionable without
        // clobbering the real placement: writing the shared key here is what let a diagnostic
        // overwrite the user's saved seam position and then contend with the running app for
        // one autosave name.
        UserDefaults.standard.set(placement,
                                  forKey: "NSStatusItem Preferred Position \(privateIdentity)")
        // Force the write out before the new item is created. AppKit reads this
        // preference during creation, and an unsynchronised write is not guaranteed to
        // be visible to that read, which would silently leave the seam in its old slot
        // and make the search above appear to converge on the wrong answer.
        UserDefaults.standard.synchronize()

        // The window-number diff has to be re-baselined against the world as it is
        // now, without our old item in it, or the new item cannot be told apart from
        // every other status item on the bar.
        windowNumbersBeforeCreation = Self.currentWindowNumbers()
        resolvedWindowNumber = nil

        item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = privateIdentity
        Self.paint(item, for: paintedState)
        currentPlacement = placement

        return awaitMeasuredFrame()?.minX
    }

    /// The length AppKit reports for the item right now.
    var length: CGFloat { item.length }

    /// Repaints the seam's gradient for a new bar state, so a palette change
    /// moves the seam and the bar glyph together instead of leaving the seam
    /// stuck on whatever state it happened to be created with.
    func repaint(for state: BarState) {
        paintedState = state
        Self.paint(item, for: state)
    }

    /// Sets `length` wide enough to push the whole tucked run off the visible
    /// bar.
    ///
    /// `width` is a REQUEST, not a guarantee. `Probe`'s own 10,000pt request
    /// was clamped by the window server to roughly 5,000pt while still
    /// honouring the push, so a caller that needs the number actually applied
    /// must read it back via `length` or `measuredFrame()` rather than
    /// trusting this argument.
    func expand(toPush width: CGFloat) {
        item.length = max(Self.restingLength, width)
    }

    /// Shrinks the seam by exactly `points`, and never below `restingLength`.
    ///
    /// The floor is load-bearing, not a defensive nicety: reaching zero would
    /// drag the entire tucked run back onto the bar in one motion, which is
    /// exactly the overflow this whole design exists to prevent. A caller
    /// that wants to end a reveal should re-expand to push the run off again,
    /// never shrink this item to nothing.
    func collapse(by points: CGFloat) {
        item.length = Self.clampedLength(current: item.length, collapsingBy: points)
    }

    /// The pure arithmetic behind `collapse(by:)`, split out so it is testable
    /// without a live status bar.
    ///
    /// `points` at or below zero is a no-op rather than growth: `collapse` is
    /// a request to get SMALLER, and letting a zero or negative delta reverse
    /// that into an expansion would surprise every caller of this method.
    /// `nonisolated` because this touches no actor state, only its own
    /// arguments and the Sendable constant `restingLength`.
    nonisolated static func clampedLength(current: CGFloat, collapsingBy points: CGFloat) -> CGFloat {
        guard points > 0 else { return current }
        return max(restingLength, current - points)
    }

    /// This item's real measured frame from the window server, or nil when it
    /// cannot yet be told apart from every other status item.
    ///
    /// Exists so `--seam` and any later reveal logic can verify a length
    /// actually took effect rather than trusting the setter, the same
    /// distinction `Probe` phase 3 draws between "spacer honoured" and
    /// "spacer clamped or ignored." Callers must let AppKit's run loop turn
    /// at least once after any length change before calling this; a scan
    /// taken in the same tick as the mutation reads stale geometry.
    func measuredFrame() -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        let scan = BarScanner.scan(menuBarRect: BarScanner.menuBarRect(for: screen))

        // ASK OURSELVES WHERE WE ARE, then find the window there.
        //
        // This used to identify our window as "the first one in the scan that was not present
        // before I created my item", caching the answer forever. Both halves were wrong, and
        // together they produced a failure that appeared only at launch and looked like the seam
        // vanishing.
        //
        // The diff races every OTHER app's items. Measured at launch: Stow's three real windows
        // were 70228, 70230 and 70232, and the seam resolved to 70231, a window created and
        // destroyed by something else in between. Caching then made that permanent, and because
        // the cached branch returned nil for the frame while `windowNumber` still handed out the
        // stale number, an arrange failed every single move with "the seam has no live window"
        // for a seam plainly sitting on the bar.
        //
        // `button?.window` reports a placeholder NUMBER, measured as 4294967296, exactly 2^32,
        // because macOS hosts the real window in Control Center. But it reports a REAL FRAME.
        // Measured: an item created at 14pt reported x-4025 w30 and exactly one bar-level window
        // sat there; widened to 300pt it reported x-4311 w316 and the same window had followed
        // it. So position identifies our own item reliably, and unlike the diff it re-derives on
        // every call rather than trusting a value that may already be stale.
        guard let own = item.button?.window?.frame else { return nil }
        guard let ours = scan.items.min(by: {
            abs($0.frame.minX - own.minX) < abs($1.frame.minX - own.minX)
        }), abs(ours.frame.minX - own.minX) <= Self.ownWindowMatchTolerance else {
            return nil
        }
        resolvedWindowNumber = ours.windowNumber
        return ours.frame
    }

    /// How far a bar-level window may sit from our own reported x and still be ours.
    ///
    /// Measured as an EXACT match in both trials, at rest and expanded, so this is slack for
    /// rounding rather than for any real discrepancy. Small on purpose: the nearest neighbouring
    /// item is at least ~17pt away, so anything looser could claim it instead.
    private static let ownWindowMatchTolerance: CGFloat = 6

    /// `measuredFrame()`, but polls until the window actually exists.
    ///
    /// A status item's window does not reach `CGWindowListCopyWindowInfo` at a
    /// predictable moment after creation. A single fixed settle is therefore a coin
    /// flip: measured over six trials at 0.6s, three found the window and three did
    /// not, in both the "another instance running" and "no other instance" cases.
    /// The flake looked like a deterministic bug and sent an earlier diagnosis down
    /// a wrong path, blaming `autosaveName`, before repeat trials showed it varying
    /// run to run under identical conditions.
    ///
    /// So wait for the observable condition instead of guessing a duration. The run
    /// loop must turn between attempts or AppKit never gets to lay the item out and
    /// every poll reads the same stale world, which is why this spins the loop rather
    /// than sleeping.
    func awaitMeasuredFrame(timeout: TimeInterval = 3.0,
                            pollInterval: TimeInterval = 0.1) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
            if let frame = measuredFrame() { return frame }
        }
        return nil
    }

    /// Blocks until the seam's MEASURED width satisfies `predicate`, and returns it.
    ///
    /// `awaitMeasuredFrame` waits only for the window to become findable, which is a
    /// different question and not enough after a length change: the window exists
    /// throughout, so that method returns immediately with the OLD width. A caller that
    /// needs a new length to have actually taken effect has to poll for that, and one that
    /// sleeps a guessed duration instead gets the previous state.
    ///
    /// This was measured, not supposed. A diagnostic that set `length` to 10,000 then slept
    /// 0.4s read a 17pt window, and the following pass, which had just set the length back
    /// to rest, read the 5,016pt window the earlier request had finally produced. Both
    /// measurements described a state the caller was not in, and the conclusion drawn from
    /// them was wrong in both directions.
    ///
    /// - Returns: the settled width, or nil if it never satisfied the predicate in time.
    @discardableResult
    func awaitMeasuredWidth(satisfying predicate: (CGFloat) -> Bool,
                            timeout: TimeInterval = 3.0,
                            pollInterval: TimeInterval = 0.05) -> CGFloat? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
            if let width = measuredFrame()?.width, predicate(width) { return width }
        }
        return nil
    }

    /// How many status items existed before this one was created. Diagnostic only.
    var windowCountBeforeCreation: Int { windowNumbersBeforeCreation.count }

    /// Whether a window number was already present before this item was created.
    /// Diagnostic only, so a failure can name which windows were candidates.
    func wasPresentBeforeCreation(_ number: CGWindowID) -> Bool {
        windowNumbersBeforeCreation.contains(number)
    }

    /// How many items in a scan are NOT accounted for by the pre-creation snapshot.
    /// Exactly one is expected, ours. Zero means our item never reached the scan;
    /// more than one means another app created items in the same window and the
    /// diff can no longer identify us alone.
    func unrecognisedItemCount(in scan: BarScanner.ScanResult) -> Int {
        scan.items.filter { !windowNumbersBeforeCreation.contains($0.windowNumber) }.count
    }

    /// Removes the item from the bar. The user's tucked run has nowhere to
    /// surface once this is gone, so this is only ever called on quit or a
    /// deliberate teardown, never as part of ordinary reveal flow.
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
        // A non-persisting seam's placement key is a throwaway scoped to this process, so it
        // is removed with the item. Leaving it behind would accumulate one stale preference
        // per diagnostic run, and the whole reason the key is private is that nothing outside
        // this process should ever read it.
        if !persistPlacement {
            UserDefaults.standard.removeObject(
                forKey: "NSStatusItem Preferred Position \(privateIdentity)")
        }
    }

    // MARK: - appearance

    /// Draws NOTHING. The seam is a gap, not a mark.
    ///
    /// It used to draw a full-height gradient across `StowGlyph.paint(for:)`'s stops,
    /// per design §4, which called the footprint "the point". On a real bar that reads as
    /// a large bright block sitting among the icons, and it was reported as exactly that:
    /// too big, and obviously a second thing Stow had added.
    ///
    /// Ice and Bartender both solve this the same way and it is worth stating plainly:
    /// their spacers are INVISIBLE in the bar. The coloured dividers a user sees in those
    /// apps appear only in their preferences windows, as a picture of the arrangement. In
    /// the bar itself there is a gap and nothing else.
    ///
    /// So Stow's seam is now an empty button: no image, no title. It still costs its
    /// ~17pt of bar, because macOS pads every status item and that floor cannot be
    /// avoided, but it no longer announces itself. Where the cut sits is answered by the
    /// Arrange pane, which can say it in words and numbers instead of spending bar space
    /// on a decoration.
    ///
    /// The parameter is kept so callers do not change shape, and so a future state-tinted
    /// seam is a one-line edit rather than a re-plumb.
    private static func paint(_ item: NSStatusItem, for state: BarState) {
        _ = state
        item.button?.image = nil
        item.button?.title = ""
    }

    // MARK: - identity

    /// Every window number the status bar currently reports, or empty when no
    /// main screen exists to scan against. Used only to tell "our item" apart
    /// from everyone else's at the moment of creation.
    private static func currentWindowNumbers() -> Set<CGWindowID> {
        guard let screen = NSScreen.main else { return [] }
        let barRect = BarScanner.menuBarRect(for: screen)
        return Set(BarScanner.scan(menuBarRect: barRect).items.map(\.windowNumber))
    }
}

extension SpacerItem {

    /// `Stow --seam`: parks the seam at rest and reports its measured width,
    /// so the 10pt resting-length claim in design §4 is VERIFIED against the
    /// live window server rather than merely asserted by this file's own
    /// constant.
    ///
    /// Mirrors `Probe.runAndExit()`'s shape: a real `NSApplication` with an
    /// accessory activation policy so the item has a run loop to lay out in,
    /// then plain-text output in the same style.
    static func runSeamAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - seam")
        print(String(repeating: "=", count: 68))

        // `persistPlacement: false` is REQUIRED here. This runs as a second process
        // of a bundle whose main instance is usually live, and an autosaveName
        // collision between the two silently denies this item a window, which the
        // diagnostic would then report as a failure of the seam rather than of
        // itself.
        let spacer = SpacerItem(persistPlacement: false)
        if otherInstanceRunning() {
            print("note: another Stow instance is running. That is fine for this")
            print("      measurement, which deliberately does not persist placement.")
        }
        print("created spacer at rest, claimed length \(Int(restingLength)) pt.")
        print("waiting for the window server to register it...")
        // Poll for the observable condition rather than sleeping a guessed duration.
        // A fixed 0.6s settle here found the window in only half of six trials.
        guard let frame = spacer.awaitMeasuredFrame() else {
            // Say what was actually seen. A bare FATAL sends the next reader
            // guessing between "the item never became a window", "the scan's band
            // filter rejected it", and "the diff picked the wrong window", which are
            // three different bugs with three different fixes.
            print("FATAL: could not locate the seam's own window in the scan.")
            print("")
            print("  diagnostics:")
            print("    AppKit item.length   : \(spacer.length) pt")
            if let screen = NSScreen.main {
                let band = BarScanner.menuBarRect(for: screen)
                let scan = BarScanner.scan(menuBarRect: band)
                print("    band                 : x\(Int(band.minX)) y\(Int(band.minY))"
                      + " w\(Int(band.width)) h\(Int(band.height))")
                print("    items scan found     : \(scan.items.count)")
                print("    windows before create: \(spacer.windowCountBeforeCreation)")
                print("    unrecognised items   : \(spacer.unrecognisedItemCount(in: scan))")
                print("")
                print("    every status item the scan currently returns:")
                for i in scan.items {
                    print("      win\(i.windowNumber) x\(Int(i.frame.minX)) y\(Int(i.frame.minY))"
                          + " w\(Int(i.frame.width)) h\(Int(i.frame.height))"
                          + "  \(spacer.wasPresentBeforeCreation(i.windowNumber) ? "pre-existing" : "NEW")")
                }
            } else {
                print("    no main screen to scan against")
            }
            spacer.remove()
            exit(1)
        }

        // Report BOTH numbers, because they are different things and the design
        // conflates them. `length` is what AppKit was asked for and what the button
        // draws into. The window is what the bar actually gives up: macOS adds its
        // own horizontal chrome around every status item, measured at 5pt per side
        // over five consecutive runs, so a 10pt seam occupies a 20pt window. One run
        // reported 22, so treat the figure as about 20 rather than exact.
        //
        // That distinction is not pedantry. Design §15 lists "One item, roughly
        // 10pt" with confidence "certain", and `BarBudget` subtracts the real
        // occupied width, so the true cost of running Stow is about double the
        // documented figure and it comes straight out of the headroom the whole app
        // exists to manage.
        print("measured window frame    : x\(Int(frame.minX)) y\(Int(frame.minY))"
              + " w\(Int(frame.width)) h\(Int(frame.height))")
        print("AppKit item.length       : \(Int(spacer.length)) pt")
        print("claimed resting length   : \(Int(restingLength)) pt")
        let lengthHonoured = abs(spacer.length - restingLength) < 0.5
        print("length honoured          : \(lengthHonoured ? "YES" : "NO")")
        let chrome = frame.width - restingLength
        print("chrome macOS adds        : \(Int(chrome)) pt"
              + " (\(Int(chrome / 2)) pt per side)")
        print("REAL bar cost of running : \(Int(frame.width)) pt, not"
              + " \(Int(restingLength)) pt")

        spacer.remove()
        print("spacer removed.")
        exit(0)
    }

    /// Whether another process of this same bundle is already running.
    ///
    /// Reported by `--seam` so a reader knows the conditions the measurement was taken under,
    /// and a REFUSAL condition for `--move`, which cannot mean anything against a bar whose
    /// seam is expanded: an item moved into the hidden run vanishes from the scan mid-test and
    /// reads as "not on the bar".
    static func otherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == id && $0.processIdentifier != mine
        }
    }
}

extension SpacerItem {

    /// `Stow --hide`: the core-mission test. Places a seam to the right of the
    /// third-party run, expands it, and reports which items were actually pushed off
    /// the visible bar.
    ///
    /// This exists because the mechanism the whole app rests on had never been
    /// verified against real items. `Probe` phase 3 pushed a victim item it had
    /// created itself, which lands leftmost and therefore sits conveniently to the
    /// left of the seam. Every item a USER cares about was to the seam's right, where
    /// expanding cannot touch it. The first honest measurement of that was zero of
    /// eight moved, and it was not a positioning detail: it was the mission failing.
    ///
    /// The output is per-item and diffable on purpose. A screenshot cannot tell the
    /// difference between an item that moved and an item that was never there, and
    /// the whole question here is which items moved and by how much.
    static func runHideAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - hide")
        print(String(repeating: "=", count: 68))

        guard PressActionProbe.isTrusted else {
            print("  accessibility  : NO")
            print("  Without it no item can be attributed to an app, so this test")
            print("  cannot tell whose items moved. Grant it first.")
            exit(2)
        }

        let before = BarItemOwners.refreshCache()
        // Stow's OWN token is not a hide target, and must not be counted as one.
        //
        // It is deliberately placed outside the seam so a hide never removes the
        // control that undoes it, which means it is legitimately the rightmost
        // third-party item on the bar. Including it here made this diagnostic compare
        // the seam against Stow itself and print "the seam is LEFT of the items it
        // must push" at the exact moment the placement was correct.
        let ownBundle = Bundle.main.bundleIdentifier
        let thirdParty = before.filter {
            !VisibleRowIdentity.cannotBeAddressedIndividually($0.bundleID) && $0.bundleID != ownBundle
        }
        guard let rightmost = thirdParty.max(by: { $0.axLeftEdge < $1.axLeftEdge }) else {
            print("  no third-party items on the bar, so there is nothing to hide")
            exit(1)
        }

        print("  third-party items  : \(thirdParty.count) (excluding Stow's own token)")
        print("  rightmost of them  : \(rightmost.name) at x\(Int(rightmost.axLeftEdge))")
        print("  placement recorded : "
              + (recordedPlacement(for: .tucked).map(String.init) ?? "none"))

        // Place BEFORE creating: AppKit reads the preference at creation time.
        place(.tucked)
        let seam = SpacerItem(state: .tidy)
        guard let restFrame = seam.awaitMeasuredFrame() else {
            print("  the seam never reached the window server, so nothing was measured")
            seam.remove()
            exit(1)
        }
        print("  seam landed at     : x\(Int(restFrame.minX)) w\(Int(restFrame.width))")

        let placedRight = restFrame.minX > rightmost.axLeftEdge
        print("  right of the run   : \(placedRight ? "YES" : "NO")")
        if !placedRight {
            print("")
            print("  The seam is LEFT of the items it must push, so expanding it cannot")
            print("  move them. This is the exact condition that made an earlier run")
            print("  report zero of eight moved.")
        }

        print("")
        print("  expanding the seam...")
        seam.expand(toPush: 10_000)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let expanded = seam.measuredFrame()
        print("  seam width now     : \(expanded.map { "\(Int($0.width))pt" } ?? "unmeasurable")")

        let after = BarItemOwners.refreshCache()
        print("")
        print("  " + pad("APP", 24) + pad("BEFORE", 9) + pad("AFTER", 9) + "RESULT")
        var pushed = 0
        var stayed = 0
        for item in thirdParty.sorted(by: { $0.axLeftEdge < $1.axLeftEdge }) {
            let beforeX = Int(item.axLeftEdge)
            let now = after.first { $0.pid == item.pid && $0.name == item.name }
            guard let now else {
                pushed += 1
                let line = pad(item.name, 24) + pad("x\(beforeX)", 9) + pad("gone", 9)
                print("  " + line + "PUSHED OFF")
                continue
            }
            let afterX = Int(now.axLeftEdge)
            let delta = afterX - beforeX
            let offBar = now.axLeftEdge < 0
            if offBar || delta < -50 { pushed += 1 } else { stayed += 1 }
            let verdict: String
            if offBar {
                verdict = "PUSHED OFF"
            } else if delta < -50 {
                verdict = "moved \(delta)pt"
            } else {
                verdict = "unchanged"
            }
            let line = pad(item.name, 24) + pad("x\(beforeX)", 9) + pad("x\(afterX)", 9)
            print("  " + line + verdict)
        }
        print("  pushed: \(pushed)   unchanged: \(stayed)")

        // Always restore. A diagnostic that leaves the user's bar collapsed would be
        // worse than one that reported nothing.
        seam.expand(toPush: restingLength)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        seam.remove()
        print("  seam removed, bar restored")
        exit(pushed > 0 ? 0 : 1)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
}

/// Whether a bundle identifier belongs to Apple. Shared by the diagnostics and the
/// panel so both answer the question the same way.
enum VisibleRowIdentity {
    static func isApple(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.hasPrefix("com.apple.")
    }

    /// Whether Stow's zoning key, the bundle identifier, cannot single out this item
    /// among its siblings, which is the only honest reason to exclude it from zoning.
    ///
    /// NOT the same question as `isApple`. A live test synthesised the same
    /// command-drag `ItemMover` uses against the Apple-owned Kerberos extra and it
    /// MOVED, from x1153 to x1228, so "Apple item" was never a reason a move fails and
    /// the blanket exclusion predates `ItemMover` having been proven against one.
    ///
    /// Control Center is different in KIND, not degree. The accessibility walk in
    /// `BarItemOwners.claims()` found six visible items, Clock, Control Center, Sound,
    /// Wi-Fi, Battery and Now Playing, all reporting the single bundle id
    /// `com.apple.controlcenter`. Zoning is keyed on bundle id, so those six can never
    /// be addressed one at a time: asking to zone one asks to zone all six, whichever
    /// is meant. That is a real limit of the key, not a policy choice about Apple, so
    /// it is named on that ground and nothing else.
    static func cannotBeAddressedIndividually(_ bundleID: String?) -> Bool {
        bundleID == "com.apple.controlcenter"
    }
}
