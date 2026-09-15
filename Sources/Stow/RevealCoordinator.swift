import AppKit
import CoreGraphics

/// Read-only presentation state for the shelf countdown. Views only compare dates against
/// this deadline.
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

/// Temporarily shows the stowed run so one app can be used, then hides it again.
///
/// This used to drag ONE item across the boundary with a synthesised Command-drag and drag it
/// back on a timer. Both halves could be refused by macOS, and both moved the pointer. Now it
/// only changes the boundary's width: shrink it so the run comes back, press the item where it
/// actually is, widen it again when the countdown ends. Nothing is moved, so nothing can fail
/// to be put back.
@MainActor
final class RevealCoordinator: ObservableObject {

    /// Why a reveal did not happen.
    enum Failure: Error, CustomStringConvertible {
        /// The app is not currently running, so there is nothing to show.
        case appNotRunning

        var description: String {
            switch self {
            case .appNotRunning: return "the app is no longer running"
            }
        }
    }

    /// What a new reveal request means for whatever is currently revealed.
    ///
    /// Kept as pure data so the decision stays testable. With the whole run shown at once the
    /// three cases collapse to "start or restart the countdown", but naming them keeps the log
    /// readable.
    enum NextStep: Equatable {
        case revealFresh
        case restartTimer
        case tuckThenRevealFresh(previous: String)

        nonisolated static func decide(currentlyRevealed: String?,
                                       requesting bundleID: String) -> NextStep {
            guard let currentlyRevealed else { return .revealFresh }
            if currentlyRevealed == bundleID { return .restartTimer }
            return .tuckThenRevealFresh(previous: currentlyRevealed)
        }
    }

    /// The app the current reveal was for, or nil when the run is not out for a reveal.
    private(set) var revealedBundleID: String?

    /// The same deadline as the live re-hide timer, published for the shelf tile.
    @Published private(set) var presentation: RevealPresentation?

    var isRevealing: Bool { revealedBundleID != nil }

    /// Fires the re-hide. Replaced whenever a reveal is restarted, so only one is ever live.
    private var retuckTimer: DispatchSourceTimer?

    /// What to do when the countdown ends. Stored on the main actor rather than captured by the
    /// timer handler, because the handler must be `@Sendable` and a plain closure is not.
    private var retuckAction: (() -> Void)?

    static let shared = RevealCoordinator()

    private init() {}

    /// Cancels the pending re-hide. Show Everything is an emergency boundary: once the user asks
    /// for the full bar, no timer from an earlier reveal may hide it again behind their back.
    func cancelPendingRetucks() {
        retuckTimer?.cancel()
        retuckTimer = nil
        revealedBundleID = nil
        presentation = nil
        retuckAction = nil
        Self.log("cancelled pending re-hide")
    }

    /// Where the re-hide timer runs. A background queue, because the user is interacting with a
    /// menu, and a main-thread `Timer` does not fire while `NSMenu` runs its tracking loop.
    private let timerQueue = DispatchQueue(label: "dev.starkpat.stow.reveal-retuck")

    /// Shows the stowed run for `duration`, then calls `retuck`.
    ///
    /// - Parameters:
    ///   - pid: the process this reveal is for. Checked before anything changes, because the
    ///     caller resolved it from a panel snapshot and the app may have quit since.
    ///   - show: shrinks the boundary so the run is visible. Idempotent.
    ///   - retuck: widens it again. Called once, on the main actor, when the countdown ends and
    ///     this reveal is still the current one.
    func reveal(bundleID: String,
                pid: pid_t,
                duration: TimeInterval,
                show: () -> Void,
                retuck: @escaping () -> Void) throws {
        let began = Date()
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            Self.log("reveal \(bundleID) FAILED: the app is no longer running")
            throw Failure.appNotRunning
        }
        let step = NextStep.decide(currentlyRevealed: revealedBundleID, requesting: bundleID)
        show()
        revealedBundleID = bundleID
        retuckAction = retuck
        scheduleRetuck(bundleID: bundleID, duration: duration)
        Self.log("reveal \(bundleID) \(step) in \(String(format: "%.2f", Date().timeIntervalSince(began)))s pointerMoves=0")
    }

    /// Starts (or restarts) the countdown to hide the run again.
    ///
    /// MUST be a `DispatchSourceTimer` on a background queue, never a main-thread `Timer`: a
    /// main-thread `Timer` does not fire while an `NSMenu` is tracking, and the entire premise here
    /// is that the user is looking at a menu the reveal opened.
    private func scheduleRetuck(bundleID: String, duration: TimeInterval) {
        retuckTimer?.cancel()

        let startedAt = Date()
        presentation = RevealPresentation(
            bundleID: bundleID,
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(duration))

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + duration)
        // `@Sendable` IS LOAD-BEARING. This class is `@MainActor`, so a closure literal here inherits
        // that isolation; Dispatch runs it on `timerQueue` anyway and Swift 6's executor check traps.
        // Measured as EXC_BREAKPOINT exactly 16s after a 15s reveal. Nothing isolated may be touched
        // here: the real work hops to the main actor through a `Task`.
        timer.setEventHandler { @Sendable in
            RevealCoordinator.log("re-hide \(bundleID) timer fired")
            Task { @MainActor in
                RevealCoordinator.shared.retuckIfStillRevealing(bundleID: bundleID)
            }
        }
        timer.resume()
        retuckTimer = timer
        Self.log("re-hide \(bundleID) scheduled for \(String(format: "%.1f", duration))s")
    }

    /// The timer's firing, back on the main actor. Checks the bundle id again, because a later
    /// reveal may have replaced this one and a stale fire must not hide what the user just opened.
    private func retuckIfStillRevealing(bundleID: String) {
        guard revealedBundleID == bundleID else {
            Self.log("re-hide \(bundleID) declined: revealed is now \(revealedBundleID ?? "nothing")")
            return
        }
        let action = retuckAction
        revealedBundleID = nil
        presentation = nil
        retuckAction = nil
        retuckTimer = nil
        action?()
        Self.log("re-hide \(bundleID) done pointerMoves=0")
    }

    nonisolated static func log(_ message: String) {
        StowLog.append(message)
    }

    /// Resolves one hidden item whose application reports AX's `x = -1` sentinel.
    ///
    /// ACME does this while stowed: its real window server item remains at x-3930, but its AX child
    /// reports x=-1, so normal position matching cannot connect the two. Conservative on purpose:
    /// the app must own exactly one sentinel item and exactly one unclaimed hidden window may remain.
    static func uniqueSentinelItem(
        bundleID: String,
        identities: [BarItemOwners.Owner],
        items: [ObservedItem]
    ) -> ObservedItem? {
        let sentinels = identities.filter {
            $0.bundleID == bundleID && $0.axLeftEdge == -1
        }
        guard sentinels.count == 1 else { return nil }

        let positioned = identities.filter { $0.axLeftEdge != -1 }
        let plausibleHidden = items.filter {
            $0.frame.minX < 0
                && $0.frame.width > 0
                && $0.frame.width <= 400
                && $0.owner(in: positioned) == nil
        }
        guard plausibleHidden.count == 1 else { return nil }
        return plausibleHidden[0]
    }
}
