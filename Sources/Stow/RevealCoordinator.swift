import AppKit
import CoreGraphics

/// Read-only presentation state for the shelf countdown. Movement stays owned by
/// `RevealCoordinator`; views only compare dates against this deadline.
struct RevealPresentation: Equatable, Sendable {
    let bundleID: String
    let startedAt: Date
    let deadline: Date

    nonisolated func progress(at date: Date) -> Double {
        let duration = deadline.timeIntervalSince(startedAt)
        guard duration > 0 else { return 0 }
        return min(1, max(0, deadline.timeIntervalSince(date) / duration))
    }

    nonisolated func secondsRemaining(at date: Date) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    nonisolated func matches(_ candidate: String) -> Bool {
        bundleID == candidate
    }
}

/// Temporarily brings ONE tucked app's status item back onto the visible bar, lets the
/// user interact with it, then puts it back.
///
/// This exists because `onOpenHidden` used to press a hidden item through accessibility
/// while it stayed off-screen at a large negative x. The press opened a menu, but the
/// item itself was neither visible nor usable: reported directly, and true of any item
/// whose interaction is more than "open the menu and read it," a text field or a
/// checkbox the user actually needs to touch.
///
/// WHAT IT RE-RESOLVES, AND WHAT IT REMEMBERS. It moves items, so it needs live window ids, and
/// the two halves are not treated alike. The SEAM is asked for afresh every time, because changing
/// a status item's placement destroys and recreates it, so its window number really is unstable.
/// The moved ITEM's id is remembered, because window ids were measured to SURVIVE a move: diffing
/// every bar-level id before and after one showed none vanished and none appeared, only the order
/// changed. This header used to claim the opposite, that nothing is carried across a move, which
/// `revealedWindow` exists specifically to do and which re-resolving by accessibility position had
/// already been measured failing, because that tree lags the window server.
@MainActor
final class RevealCoordinator: ObservableObject {

    /// Why a reveal did not happen.
    enum Failure: Error, CustomStringConvertible {
        /// `HideController.tuckedSeamWindow()` returned nil: the seam has no live window
        /// yet, so "right of the seam" cannot be expressed.
        case noSeamWindow
        /// The app is not currently running, so there is no window to bring back.
        case appNotRunning
        /// `ItemMover.positionableItems()` has no item whose owner resolves to this bundle id.
        case itemNotFound(bundleID: String)
        /// `ItemMover.move` itself refused or failed.
        case moveFailed(ItemMover.Failure)

        var description: String {
            switch self {
            case .noSeamWindow:
                return "the tucked seam has no live window, so there is no boundary to reveal against"
            case .appNotRunning:
                return "the app is no longer running"
            case .itemNotFound(let bundleID):
                return "no bar item resolves to \(bundleID)"
            case .moveFailed(let failure):
                return "\(failure)"
            }
        }
    }

    /// What to do about whatever is CURRENTLY revealed when a new reveal request
    /// arrives, decided before any item is touched.
    ///
    /// Split out as pure data so the decision is testable without a live bar: this type
    /// carries no window ids or dates, only the bundle ids the caller already knows.
    enum NextStep: Equatable {
        /// Nothing is revealed. Move the requested item and start its timer.
        case revealFresh
        /// The requested item is ALREADY the one revealed. Restart its timer without
        /// moving anything, since it already sits on the visible side of the seam.
        case restartTimer
        /// A DIFFERENT item is revealed. Put it back first, then reveal the requested
        /// one. `ItemMover` only ever moves one item at a time, so failing to put the
        /// first back here is exactly how it would leak onto the bar permanently.
        case tuckThenRevealFresh(previous: String)

        /// The decision itself, given what is revealed now and what was just asked for.
        ///
        /// `nonisolated` and static: this touches no actor state, only its own two
        /// strings, so a test can drive every branch with no bar, no timer, and no
        /// main-actor hop.
        nonisolated static func decide(currentlyRevealed: String?,
                                       requesting bundleID: String) -> NextStep {
            guard let currentlyRevealed else { return .revealFresh }
            if currentlyRevealed == bundleID { return .restartTimer }
            return .tuckThenRevealFresh(previous: currentlyRevealed)
        }
    }

    /// The bundle id currently sitting on the visible side of the seam, or nil when
    /// nothing is revealed. Read-only from outside: the only way to change it is
    /// through `reveal` and the retuck it schedules.
    private(set) var revealedBundleID: String?

    /// The same deadline as the live re-tuck timer, published for the one shelf tile
    /// that is temporarily on the visible bar.
    @Published private(set) var presentation: RevealPresentation?

    /// The window that was moved, remembered so the re-tuck does not have to find it again.
    ///
    /// The re-tuck used to re-resolve the item by matching an accessibility left edge to a window
    /// x within 10pt, and it failed with "no bar item resolves to it" while the item sat plainly
    /// at x1096: the accessibility tree LAGS the window server, and the reveal had moved the item
    /// ~5,000pt moments earlier. Remembering the id removes the lookup, and it is sound because
    /// window ids were measured to SURVIVE a move: diffing every bar-level id before and after
    /// one showed none vanished and none appeared, only the order changed.
    private var revealedWindow: (id: CGWindowID, hostPID: pid_t)?

    /// Whether anything is currently revealed, for a caller that only needs the yes/no.
    var isRevealing: Bool { revealedBundleID != nil }

    /// Fires the re-tuck. Cancelled and replaced whenever a reveal is restarted or a
    /// different item takes its place, so only ever one timer is live at a time.
    private var retuckTimer: DispatchSourceTimer?

    /// The RETRY nudge, separate from the countdown above, and separate on purpose.
    ///
    /// A retry was originally scheduled into `retuckTimer`, which is one slot serving two unrelated
    /// jobs, and they cancelled each other in both directions. `scheduleRetuck` cancels
    /// unconditionally, so the next reveal destroyed a pending retry; and a retry is armed at a
    /// moment when `revealedBundleID` has just been cleared by the failed retuck, so it also broke
    /// the invariant that makes `retuck`'s guarded cancel safe, namely that a live `retuckTimer`
    /// belongs to whatever `revealedBundleID` names.
    ///
    /// This one is owned by nothing in particular: it exists only to bring the app back to a moment
    /// where `drainPendingRetucks` can run, so it carries no bundle id and no identity guard.
    private var retryTimer: DispatchSourceTimer?

    /// How to ask for the tucked seam's current window, held as main-actor state.
    ///
    /// Stored rather than captured by the timer handler, and that is a concurrency requirement
    /// rather than a style choice. The handler must be `@Sendable`, because Dispatch runs it off
    /// the main actor, and a `() -> CGWindowID?` closure is not `Sendable`: capturing one made the
    /// compiler reject the handler outright. Keeping it here means the handler captures only a
    /// `String`, and the closure is read back on the main actor where it is safe to call.
    private var seamWindowLookup: (() -> CGWindowID?)?

    /// The one coordinator, owned for the life of the process.
    ///
    /// NOT a `@StateObject`, which is what this was and which does not survive. Measured from the
    /// app's own log: `init` at 06:50:24, `deinit` at 06:50:24, `init` again at 06:50:34. SwiftUI
    /// rebuilt the scene and destroyed the object, and a `DispatchSourceTimer` released by its
    /// owner is cancelled without ever running its handler, so a re-tuck already counting down
    /// vanished silently. A 15-second timer that dies on a view rebuild is worse than no timer,
    /// because the item stays revealed forever with nothing to explain it.
    static let shared = RevealCoordinator()

    private init() {}

    /// Cancels every automatic move Stow scheduled for a temporarily revealed app.
    ///
    /// Show Everything is an emergency boundary: once the user asks for the full bar,
    /// no timer or retry from an earlier reveal may move an icon again behind their back.
    func cancelPendingRetucks() {
        retuckTimer?.cancel()
        retuckTimer = nil
        retryTimer?.cancel()
        retryTimer = nil
        revealedBundleID = nil
        revealedWindow = nil
        presentation = nil
        pendingRetuck.removeAll()
        seamWindowLookup = nil
        Self.log("cancelled all pending retucks")
    }

    /// Where the re-tuck timer runs.
    ///
    /// A background queue, not `DispatchQueue.main`, because the whole point of this
    /// class is that the user is interacting with a menu the moved item just opened.
    /// See `scheduleRetuck` for why a main-thread `Timer` cannot be used here at all.
    private let timerQueue = DispatchQueue(label: "dev.starkpat.stow.reveal-retuck")

    /// Brings `bundleID`'s status item to the visible side of `seamWindow`, and
    /// schedules putting it back after `duration`.
    ///
    /// - Parameters:
    ///   - pid: the process this reveal is being requested for. Checked against
    ///     `NSRunningApplication` before anything is moved, because the caller in
    ///     `App.swift` resolves this pid from a panel snapshot and then waits out a
    ///     deliberate 120ms settle before acting on it; an app that quit in that window
    ///     must fail the reveal rather than move a window that no longer has an owner
    ///     behind it.
    ///   - seamWindow: returns the tucked seam's CURRENT window number. A closure, not a
    ///     captured value, for the same reason `BarArranger.arrange` takes one: the seam's
    ///     window number is not stable across a move, so the re-tuck this schedules must
    ///     ask again rather than trust what was true when `reveal` was called.
    func reveal(bundleID: String,
               pid: pid_t,
               seamWindow: @escaping () -> CGWindowID?,
               duration: TimeInterval) throws {
        // LOG EVERY ATTEMPT, both outcomes.
        //
        // The reveal path has no UI to report into: `App.swift` swallows the error because a
        // failed reveal still falls through to pressing the item where it stands. That is the
        // right behaviour and it is also completely silent, which is the exact condition that
        // made five earlier wiring bugs in this project invisible until an arrange log existed.
        // Measured the same way here: the first live test of this class did nothing at all and
        // there was no way to tell which of four guards had refused.
        let began = Date()
        do {
            try awaitMouseRelease()
            try attemptReveal(bundleID: bundleID, pid: pid, seamWindow: seamWindow, duration: duration)
            Self.log("reveal \(bundleID) ok in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
        } catch {
            Self.log("reveal \(bundleID) FAILED: \(error)")
            throw error
        }
    }

    /// Blocks until no mouse button is held, because `ItemMover.move` refuses while one is.
    ///
    /// That refusal is correct in general: a synthesised command-drag would fight a real one. But
    /// this class is called FROM a click, so the button that asked for the reveal is frequently
    /// still down when the work starts. Measured, and it presented as the feature doing nothing at
    /// all with the log reading "a mouse button is held, so a real drag is in flight and would
    /// fight this".
    ///
    /// The run loop is spun rather than slept, because the button-up has to be delivered and
    /// processed for `NSEvent.pressedMouseButtons` to change; sleeping would wait for an event
    /// that cannot arrive. Bounded, so a genuinely stuck button fails rather than hanging the
    /// panel.
    private func awaitMouseRelease() throws {
        guard NSEvent.pressedMouseButtons != 0 else { return }
        let deadline = Date().addingTimeInterval(Self.mouseReleaseTimeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if NSEvent.pressedMouseButtons == 0 { return }
        }
        throw Failure.moveFailed(.mouseButtonHeld)
    }

    /// How long to wait for the requesting click's own button to come up.
    ///
    /// A click's press-to-release is tens of milliseconds; this is generous enough to cover a slow
    /// one and short enough that a stuck button surfaces as a failure rather than a freeze.
    private static let mouseReleaseTimeout: TimeInterval = 0.5

    private func attemptReveal(bundleID: String,
                               pid: pid_t,
                               seamWindow: @escaping () -> CGWindowID?,
                               duration: TimeInterval) throws {
        // DRAIN HELD RETUCKS FIRST, above the switch.
        //
        // Placement is load-bearing twice over. It used to sit below the switch, which meant the
        // `tuckThenRevealFresh` arm inserted a freshly-failed entry and then the drain retried that
        // same entry microseconds later, synchronously, inside the user's click, with nothing about
        // the bar having changed in between. Each attempt is a real command-drag costing up to
        // `ItemMover.worstCaseMove`, so a click could stall for twice that before the reveal the user
        // actually asked for even started.
        //
        // Above the switch it retries only entries from PRIOR reveals, and the `.restartTimer` arm
        // returns early, so that arm never drained at all despite `pendingRetuck`'s own doc promising
        // a drain "on the next reveal".
        drainPendingRetucks(seamWindow: seamWindow)

        switch NextStep.decide(currentlyRevealed: revealedBundleID, requesting: bundleID) {
        case .restartTimer:
            scheduleRetuck(bundleID: bundleID, seamWindow: seamWindow, duration: duration)
            return
        case .tuckThenRevealFresh(let previous):
            // Best-effort, and a failure is HELD rather than dropped.
            //
            // A failed tuck-back of the previous item must not block revealing the one the user just
            // asked for, or one stuck item would wedge every future click. But the state below is
            // overwritten unconditionally, so without somewhere to put it the failed item is simply
            // forgotten: nothing tracks it and it sits on the visible side of the seam permanently.
            // That is the outcome `NextStep`'s own doc warns about. `pendingRetuck` is that
            // somewhere.
            //
            // CAPTURED BEFORE THE ATTEMPT, because `retuck` clears `revealedWindow` on its way out
            // whenever the id matches, which is exactly this case by construction of
            // `NextStep.decide`. Reading it afterwards yields nil and the hold records nothing.
            let strandedWindow = revealedWindow
            if retuck(bundleID: previous, seamWindow: seamWindow) == false, let strandedWindow {
                pendingRetuck[previous] = strandedWindow
            }
        case .revealFresh:
            break
        }

        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw Failure.appNotRunning
        }
        guard let seam = seamWindow() else { throw Failure.noSeamWindow }
        let item = try resolveItem(bundleID: bundleID)

        do {
            try ItemMover.move(windowID: item.windowNumber, to: .rightOf(seam), hostPID: item.ownerPID)
        } catch let failure as ItemMover.Failure {
            throw Failure.moveFailed(failure)
        }

        // A SUCCESSFUL REVEAL SUPERSEDES ANY HELD RETUCK FOR THE SAME ITEM.
        //
        // Without this the two states coexist and the item can never be given up: it is revealed, so
        // its window is on the visible bar by definition, so the give-up test in the drain can never
        // fire for it. Every later drain then pays a full failed move for an entry that is stale by
        // construction, and because `revealedBundleID` now matches, the guarded cancel inside
        // `retuck` fires FROM the drain and destroys this item's live countdown. Reachable: a retuck
        // fails and holds the item, then the user clicks that same item, whose `rightOf` move
        // returns immediately because it is already there.
        pendingRetuck.removeValue(forKey: bundleID)
        revealedBundleID = bundleID
        revealedWindow = (item.windowNumber, item.ownerPID)
        scheduleRetuck(bundleID: bundleID, seamWindow: seamWindow, duration: duration)
    }

    /// Puts `bundleID`'s item back to the left of the seam, right now, cancelling whatever retuck
    /// timer was pending for it.
    ///
    /// - Returns: whether the item actually moved. The caller needs this: a failure has to be
    ///   recorded somewhere or the item is lost, and this function cannot record it itself because
    ///   the state it would use is about to be overwritten by the reveal that called it.
    ///
    /// Failure is not thrown, because one caller is the timer path where there is no caller left to
    /// hand an error to. It is logged, and reported through the return value.
    ///
    /// This used to claim `revealedBundleID` was "deliberately left set on failure, since the item
    /// did not actually move". It was not: the clear below runs whether the move succeeded or not,
    /// and it always did. The claim mattered because it was the stated reason a failure was
    /// recoverable, so the recovery it promised did not exist. `pendingRetuck` is the real
    /// mechanism, and the return value is how a caller reaches it.
    @discardableResult
    private func retuck(bundleID: String, seamWindow: @escaping () -> CGWindowID?) -> Bool {
        // CANCEL THE TIMER ONLY IF IT IS THIS ITEM'S TIMER.
        //
        // It used to cancel unconditionally, which is right when retucking the item that is out but
        // wrong for a `pendingRetuck` retry, and the retry path is new. Trace: B is revealed with a
        // 15s timer pending, a drain retries stranded item A, `retuck(A)` cancels the one timer, and
        // B is never put back automatically. That trades one stranded item for another, which is the
        // whole defect this retry mechanism exists to fix.
        if revealedBundleID == bundleID {
            retuckTimer?.cancel()
            retuckTimer = nil
            presentation = nil
        }

        guard let seam = seamWindow() else {
            Self.log("retuck \(bundleID) FAILED: the seam has no live window")
            return false
        }
        // The window REMEMBERED from the reveal, falling back to a lookup only if there is none.
        // The fallback covers a retuck for an item this coordinator did not itself reveal, which is
        // the `pendingRetuck` drain below, since by then `revealedWindow` names a different app.
        guard let window = pendingRetuck[bundleID]
            ?? (revealedBundleID == bundleID ? revealedWindow : nil)
            ?? (try? resolveItem(bundleID: bundleID)).map({ ($0.windowNumber, $0.ownerPID) })
        else {
            Self.log("retuck \(bundleID) FAILED: no window is known for it")
            return false
        }
        var moved = false
        do {
            try ItemMover.move(windowID: window.0, to: .leftOf(seam), hostPID: window.1)
            Self.log("retuck \(bundleID) ok")
            moved = true
            pendingRetuck.removeValue(forKey: bundleID)
        } catch {
            Self.log("retuck \(bundleID) FAILED: \(error)")
        }
        if revealedBundleID == bundleID {
            revealedBundleID = nil
            revealedWindow = nil
        }
        return moved
    }

    /// Items a retuck failed to put back, held so a later attempt can.
    ///
    /// Keyed by bundle id, holding the window that was moved out. Drained on the next reveal and on
    /// every timer fire, which are the two moments a seam is known to exist and the bar is known to
    /// be in a state where a move can land. Bounded by the number of apps that have ever failed a
    /// retuck, since the key is the bundle id and a repeat failure overwrites rather than
    /// accumulates. An entry is removed when a retry succeeds, or given up when the window it holds
    /// is no longer on the bar at all.
    private var pendingRetuck: [String: (id: CGWindowID, hostPID: pid_t)] = [:]

    /// Retries every held retuck, giving up on any whose window has left the bar.
    ///
    /// Called from the reveal path and the timer path rather than on a schedule of its own, because a
    /// retry wants a live seam and both callers are at a moment where one normally exists. Neither
    /// GUARANTEES it: the reveal-path call runs above that path's own seam guard, so the nil case is
    /// handled inside `retuck` rather than screened here.
    ///
    /// The give-up rule used to be "the app is no longer running", which is a different question: an
    /// app can keep running with its menu bar icon turned off, and that entry was then retried on
    /// every click for the life of the process.
    private func drainPendingRetucks(seamWindow: @escaping () -> CGWindowID?) {
        guard pendingRetuck.isEmpty == false else { return }

        // BUDGETED, for the reason `BarArranger` is. Each retry is a synchronous `ItemMover.move` on
        // the main actor costing up to `ItemMover.worstCaseMove`, so an unbounded loop over k stuck
        // apps blocks the main actor for k times that. That is the same failure shape the arrange
        // move loop is bounded against, and it would have been reintroduced here by the same change
        // that bounded the other one. Entries not reached stay held for the next opportunity, and
        // both callers recur, so nothing is lost by stopping early.
        let deadline = Date().addingTimeInterval(Self.drainBudget)

        // A SNAPSHOT of the keys. `retuck` removes its own entry on success and this loop removes
        // entries it gives up on, so iterating the live dictionary would read a collection while
        // mutating it. Copy-on-write makes that memory-safe rather than undefined, but the loop would
        // keep visiting entries already removed, so the snapshot is for clarity as much as safety.
        // NEVER THE ITEM THAT IS CURRENTLY OUT. It is out on purpose, with its own countdown, so a
        // retry would tuck away what the user just asked to see, and `retuck`'s guarded cancel would
        // take its countdown with it. Belt and braces with the supersede above: that removes the
        // entry, this makes the drain safe even if some future path reintroduces one.
        for bundleID in Array(pendingRetuck.keys) where bundleID != revealedBundleID {
            guard Date() < deadline else { return }

            // GIVE UP when the item no longer has a window to move, which is the condition this map's
            // doc always described and the code did not implement. It tested whether the APP was
            // running, which is a different question: an app can keep running after the user turns
            // its menu bar icon off in its own settings, and with no attempt cap that entry was
            // retried on every click and every timer fire for the life of the process, each one
            // costing a full failed move. A missing window is the honest end of the road.
            // The two nil cases are told apart, because conflating them logged a false cause. A
            // missing ENTRY means it was handled while this loop ran, since `ItemMover.move` spins the
            // run loop and can deliver a click that re-enters; the key snapshot then goes stale. A
            // present entry whose WINDOW is gone is the real give-up.
            guard let held = pendingRetuck[bundleID] else { continue }
            guard ItemMover.positionableItems().contains(where: { $0.windowNumber == held.id }) else {
                Self.log("retuck \(bundleID) given up: its window is gone, so there is nothing to move")
                pendingRetuck.removeValue(forKey: bundleID)
                continue
            }
            _ = retuck(bundleID: bundleID, seamWindow: seamWindow)
        }
    }

    /// How long one drain may spend retrying held retucks.
    ///
    /// Below one `ItemMover.worstCaseMove`, which is what actually delivers "one retry per drain".
    ///
    /// It was 6.0s, ABOVE the 5.25s a fully-retried move costs, so after a first retry exhausted its
    /// attempts the guard still passed and a second started: 10.5s of synchronous main-actor time
    /// inside a click, which is the opposite of what its own comment claimed. The doc also called it
    /// tighter than the arrange's budget when the arrange's is 3.0s.
    ///
    /// At 3.0s the guard cannot pass twice after a full-cost retry, so one stuck item gets one real
    /// attempt per drain and the rest stay held for the next. Matching `BarArranger.totalBudget`
    /// deliberately: the two are the same kind of promise about how long the main actor may be held.
    /// Not `private`: the tests pin its relationship to `ItemMover.worstCaseMove`, because it shipped
    /// on the wrong side of that boundary and nothing caught it.
    static let drainBudget: TimeInterval = 3.0

    /// Starts (or restarts) the countdown to put `bundleID` back.
    ///
    /// MUST be a `DispatchSourceTimer` on a background queue, never a main-thread
    /// `Timer`. `BUILD-PLAN.md` records this as a measured hazard
    /// rather than a theoretical one: a main-thread `Timer` does not fire while an
    /// `NSMenu` is running its nested tracking run loop, and the entire premise of this
    /// class is that the user is looking at a menu the just-moved item opened. A timer
    /// that only fires after that menu closes is not a 15-second auto-tuck, it is a
    /// tuck-on-next-unrelated-event, and the first person to "simplify" this back to
    /// `Timer` will reintroduce exactly that bug with no compiler warning to catch it.
    ///
    /// The handler runs on `timerQueue`, so it hops back to the main actor itself before
    /// touching anything `@MainActor`; that hop is what `retuckIfStillRevealing` is for.
    private func scheduleRetuck(bundleID: String,
                                seamWindow: @escaping () -> CGWindowID?,
                                duration: TimeInterval) {
        retuckTimer?.cancel()

        let startedAt = Date()
        presentation = RevealPresentation(
            bundleID: bundleID,
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(duration))

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + duration)
        // `@Sendable` IS LOAD-BEARING, and leaving it off crashed the app every time.
        //
        // This class is `@MainActor`, so a closure literal written here INHERITS main-actor
        // isolation. Dispatch then runs it on `timerQueue` anyway, and Swift 6's executor check
        // traps: measured as EXC_BREAKPOINT / SIGTRAP in `Stow-2026-08-18-005546.ips`, exactly 16
        // seconds after a reveal that had asked for 15. From the outside this was indistinguishable
        // from a timer that simply never fired, which is why it survived three rounds of looking at
        // the timer itself. `@Sendable` makes the closure non-isolated, which is what it actually
        // is.
        //
        // Nothing isolated may be touched here as a result. `log` is `nonisolated static`, and the
        // real work hops to the main actor through a `Task`, which is also the only place `self`
        // may be read.
        seamWindowLookup = seamWindow
        timer.setEventHandler { @Sendable in
            RevealCoordinator.log("retuck \(bundleID) timer fired")
            Task { @MainActor in
                RevealCoordinator.shared.retuckIfStillRevealing(bundleID: bundleID)
            }
        }
        timer.resume()
        retuckTimer = timer
        // Kept, not scaffolding. Without it the log cannot tell "never scheduled" from "scheduled
        // and never fired", and those have completely different causes: the first is a logic path
        // not reached, the second was a Swift 6 executor trap that crashed the app 16 seconds
        // later. Three rounds of diagnosis were spent on the timer because this line had been
        // removed and both looked identical from outside.
        Self.log("retuck \(bundleID) scheduled for \(String(format: "%.1f", duration))s")
    }

    /// The timer's actual firing, back on the main actor.
    ///
    /// Checks `revealedBundleID` again rather than trusting the bundle id it was
    /// scheduled with, because a second `reveal` call for a DIFFERENT app already ran
    /// `retuck` for this one synchronously and cleared this timer; a stale fire arriving
    /// anyway (the cancel and the fire racing) must not move an item that is no longer
    /// this coordinator's business.
    private func retuckIfStillRevealing(bundleID: String) {
        guard let seamWindow = seamWindowLookup else {
            Self.log("retuck \(bundleID) FAILED: no seam lookup was stored")
            return
        }
        // Retry anything held, whatever this fire turns out to be for. A timer fire is the other
        // moment a seam is known to exist, and an item stranded on the visible bar should not have
        // to wait for the user to click something before Stow tries again.
        drainPendingRetucks(seamWindow: seamWindow)

        guard revealedBundleID == bundleID else {
            Self.log("retuck \(bundleID) declined: revealed is now \(revealedBundleID ?? "nothing")")
            return
        }
        // CAPTURE BEFORE THE ATTEMPT. `retuck` clears `revealedWindow` on its way out, so reading
        // it afterwards yields nil and the hold would record nothing.
        let window = revealedWindow ?? pendingRetuck[bundleID]
        if retuck(bundleID: bundleID, seamWindow: seamWindow) == false, let window {
            pendingRetuck[bundleID] = window
            // AND ARM ONE RETRY NUDGE. Deliberately one, not a loop.
            //
            // The two drain sites are a reveal and a timer fire. A timer is one-shot, so without this
            // a timer-path failure left the item held with nothing at all to retry it, waiting for the
            // user to click something else.
            //
            // The nudge does not re-arm itself, so after it fails the item IS waiting for a click
            // again. That is the policy rather than an oversight: each attempt is a synchronous
            // `ItemMover.move` costing up to `ItemMover.worstCaseMove`, so an item that cannot be put
            // back would tax every timer fire forever. One free attempt, then the next thing the user
            // does. Do not describe this as a durable retry: it is one nudge and then a wait, and the
            // release note says so in those terms.
            scheduleRetry()
        }
    }

    /// Arms a one-shot nudge that simply runs `drainPendingRetucks` later.
    ///
    /// Deliberately not `scheduleRetuck`. That schedules `retuckIfStillRevealing(bundleID)`, which
    /// guards on `revealedBundleID == bundleID`, and the caller here has just had that cleared by the
    /// failed retuck, so the fire would decline immediately and log a misleading "declined" line for
    /// an item that is genuinely still out. It also shares the countdown's timer slot.
    ///
    /// Replaces rather than stacks: a second failure while a nudge is pending should push the nudge
    /// out, not queue two.
    private func scheduleRetry() {
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + Self.retryInterval)
        // `@Sendable`, for the reason `scheduleRetuck`'s handler is: a closure written inside a
        // `@MainActor` type inherits that isolation, Dispatch runs it off the main actor anyway, and
        // Swift 6's executor check traps. That crash was measured once already on this class.
        //
        // It therefore captures NOTHING but the shared instance, and reads the seam lookup back from
        // `seamWindowLookup` inside the hop. A `() -> CGWindowID?` is not `Sendable`, so capturing one
        // is rejected outright, which is the same wall `scheduleRetuck` hit and the same answer.
        timer.setEventHandler { @Sendable in
            Task { @MainActor in
                let coordinator = RevealCoordinator.shared
                guard let seamWindow = coordinator.seamWindowLookup else {
                    RevealCoordinator.log("retry nudge fired but no seam lookup was stored")
                    return
                }
                coordinator.drainPendingRetucks(seamWindow: seamWindow)
            }
        }
        timer.resume()
        retryTimer = timer
        Self.log("retry nudge armed for \(String(format: "%.1f", Self.retryInterval))s")
    }

    /// How long to wait before retrying a retuck that failed on the timer path.
    ///
    /// Shorter than the DEFAULT reveal duration of 15s, not than any: `Config.revealDuration` floors
    /// at 1s, so a user who sets 1 or 2 gets a retry interval longer than their reveal, which is
    /// harmless but not what an unqualified "shorter" would claim. The item is already on the visible
    /// user is not looking at a countdown any more; long enough that a transient refusal, a held
    /// mouse button or a modifier, has plausibly cleared. `ItemMover` refuses outright while either
    /// is true, which is the most likely reason a retuck failed rather than errored.
    private static let retryInterval: TimeInterval = 3.0

    /// Appends one line to the same log the arrange path writes.
    ///
    /// One file, not two, because the two paths interleave on a real bar: a reveal happening
    /// between two arranges is exactly the sequence worth reading in order.
    /// Delegates to `BarArranger.append`, which owns the file.
    ///
    /// This used to carry its own copy of the directory, the filename and the append-or-create
    /// dance. Two writers to one interleaved file is precisely the case where the write mechanism
    /// must not be duplicated: the single-file property this class's own comment relies on was held
    /// by two implementations agreeing, including both remembering to terminate their line.
    nonisolated static func log(_ message: String) {
        BarArranger.append(message)
    }

    /// Resolves `bundleID` to its live bar item.
    ///
    /// The two paragraphs that used to sit here were attached to `log` above, which resolves
    /// nothing and reads no claims, leaving this function undocumented and that one carrying three
    /// paragraphs about item resolution. They also said this used "fresh cached claims", which the
    /// body contradicts: it takes a fresh uncached walk, for the reason stated inline.
    private func resolveItem(bundleID: String) throws -> ObservedItem {
        // `identities()` and `positionableItems()`, NOT `cachedClaims()` and `barItems()`,
        // and both halves of that matter for the same reason: a tucked item is off the visible bar,
        // and the ordinary pair deliberately excludes it. `claims()` drops any owner at a
        // non-positive x, and `barItems()` drops any window left of the bar, so the pair can never
        // resolve the one item this class exists to move. Measured: with zoom.us tucked, its owner
        // sat at x-3994 and its window at x-3993, and neither appeared in the ordinary pair.
        //
        // A FRESH WALK, not `cachedIdentitiesList()`. That cache is keyed on the set of running
        // pids, which is right for "who owns a bar item" and wrong for "where is it": tucking an
        // app moves its item ~5,000pt without starting or stopping a single process, so the cache
        // stays valid while every position in it goes stale. Measured, and it presented as this
        // whole feature silently doing nothing: the cache still held zoom.us near x1005 from
        // before it was tucked, its window was at x-3995, and `owner(of:in:)` matches on nearest
        // left edge within 10pt, so nothing resolved. The walk costs about 0.26s with the 50ms
        // per-app messaging timeout, which is affordable once per click and is not affordable
        // per move, which is why the arrange path keeps using its own cache.
        let identities = BarItemOwners.identities()
        guard let item = ItemMover.positionableItems()
            .first(where: { $0.owner(in: identities)?.bundleID == bundleID })
        else { throw Failure.itemNotFound(bundleID: bundleID) }
        return item
    }
}
