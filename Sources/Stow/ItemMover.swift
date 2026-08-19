import AppKit
import CoreGraphics

/// Moves ANOTHER application's menu bar item, by synthesising the command-drag a user would
/// perform by hand.
///
/// WHY THIS EXISTS. Stow's placement cost is not the hiding, it is the arranging. Hiding is a
/// single `length` write and is instant. Arranging means putting the seam on the correct side
/// of an app, and a seam can only move by being destroyed and recreated, because macOS reads
/// `NSStatusItem Preferred Position` only at item creation. Measured by `--probecost`, one
/// reposition costs a mean of 0.415s, the placement preference resolves to a coarse SLOT
/// rather than a pixel so finding the right one takes a five-probe bisection, and an apply
/// runs two of those. That is about 4.2s of a 5.6s drag, and three separate attempts to cut
/// the probe count all failed their correctness gate.
///
/// This inverts the problem. Instead of moving the seam to fit the apps, move the APPS to the
/// correct side of a seam that never moves. Measured here, one item move costs 0.165-0.187s
/// against 0.415s for one seam reposition, and a re-zone needs one move rather than ten
/// repositions.
///
/// HOW IT WORKS, and every part of this was established by measurement rather than by
/// reading:
///
///   - The item is targeted by WINDOW ID in the event fields, not by where the pointer is.
///     The mouse-down is fabricated at (20_000, 20_000), off-screen.
///   - The cursor IS moved by this, and must be put back. Posting a mouse event carries a
///     cursor position and the window server applies it, so that off-screen point drags the
///     user's real pointer off the display. It is hidden for the duration and warped back on
///     every exit path. An earlier version of this comment claimed the pointer was never
///     involved; the diagnostic disproved that within one run.
///   - A plain `event.post(tap: .cgSessionEventTap)` does NOTHING. The item does not move.
///     Verified before this file existed.
///   - What works is an ordering dance: a tap on the HOSTING process, a listen-only tap on
///     the session, and the real event posted from inside the first tap's callback. The event
///     then reaches the app having traversed the session tap, which is what makes it
///     indistinguishable from a real drag.
///   - Between the mouse-down and the mouse-up, the item's frame must be allowed to CHANGE.
///     Sending both back to back lands about half the time; waiting for the drag to visibly
///     begin is what makes it reliable.
///
/// The mechanism is Ice's (github.com/jordanbaird/Ice, `MenuBarItemManager`). Two differences
/// matter and both favour Stow on this OS:
///
///   - Ice identifies items via `kCGWindowOwnerPID`. On macOS 26 every menu bar item window
///     reports Control Center, third-party included, so that source cannot tell items apart.
///     Ice targets macOS 14 and its last commit predates macOS 26. Stow resolves identity
///     from each app's own `AXExtrasMenuBar` instead, which still works: `--rows` resolves 13
///     of 15 items to real bundle identifiers.
///   - Ice verifies a move by watching for a frame CHANGE. That reports a successful no-op as
///     a timeout, which cost real confusion here: an early timing run recorded 3.0s failures
///     for moves that had in fact already arrived. This verifies ORDER instead, which is the
///     thing actually being asked for.
///
/// USES ONE UNDOCUMENTED FIELD. `CGEventField(rawValue: 0x33)` carries a window identifier and
/// has no public constant. Ice uses the same raw value. Everything else here is public API.
@MainActor
enum ItemMover {

    /// Where to put the moved item, relative to another item.
    enum Destination {
        case leftOf(CGWindowID)
        case rightOf(CGWindowID)

        var targetID: CGWindowID {
            switch self {
            case .leftOf(let id), .rightOf(let id): return id
            }
        }
    }

    /// Why a move did not happen. Distinguished rather than collapsed into a bool, because
    /// "the OS refused" and "you were holding a modifier" call for different responses.
    enum Failure: Error, CustomStringConvertible {
        case noAccessibility
        /// The window exists but sits outside the visible bar, so something has pushed it off.
        case itemSweptOff(CGWindowID)
        case itemNotOnBar(CGWindowID)
        case targetNotOnBar(CGWindowID)
        case couldNotCreateEvents
        case couldNotCreateTaps
        case modifiersHeld
        case mouseButtonHeld
        case didNotLand(attempts: Int)

        var description: String {
            switch self {
            case .noAccessibility:
                return "no Accessibility grant, so synthesised events are discarded"
            case .itemSweptOff(let id):
                return "win\(id) exists but has been pushed off the visible bar,"
                     + " so a seam is expanded and nothing can be positioned against it"
            case .itemNotOnBar(let id):
                return "win\(id) is not on the bar at all"
            case .targetNotOnBar(let id):
                return "target win\(id) is not on the bar"
            case .couldNotCreateEvents:
                return "could not create the mouse events"
            case .couldNotCreateTaps:
                return "could not create the event taps"
            case .modifiersHeld:
                return "a modifier key is held, which would combine with the synthetic command"
            case .mouseButtonHeld:
                return "a mouse button is held, so a real drag is in flight and would fight this"
            case .didNotLand(let attempts):
                return "the item did not reach the requested position after \(attempts) attempt(s)"
            }
        }
    }

    /// Moves `windowID` to `destination`, verifying by ORDER and retrying a bounded number of
    /// times.
    ///
    /// - Parameter hostPID: the process hosting the item's window. On macOS 26 that is Control
    ///   Center for every item, which is exactly why the window id does the targeting.
    /// - Returns: how long the successful move took, for callers that report cost.
    @discardableResult
    static func move(windowID: CGWindowID,
                     to destination: Destination,
                     hostPID: pid_t) throws -> TimeInterval {
        guard AXIsProcessTrusted() else { throw Failure.noAccessibility }

        // Refuse while the user is mid-gesture, because a synthetic command-drag would combine
        // with a real one and produce neither outcome.
        //
        // The test is a HELD BUTTON, not cursor motion. Motion alone does not fight anything,
        // and testing for it was actively wrong here: Stow warps the pointer back after every
        // move, so its own warp read as "the user is moving the mouse" and every move after the
        // first was refused. Measured, that presented as 1 of 6 landing, which looked like the
        // mechanism being unreliable when it was the guard.
        guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            throw Failure.modifiersHeld
        }
        guard NSEvent.pressedMouseButtons == 0 else { throw Failure.mouseButtonHeld }

        let began = Date()

        // Already correct is not a failure, and checking first is free next to a move.
        if isPositioned(windowID, at: destination) {
            return Date().timeIntervalSince(began)
        }

        // THE CURSOR REALLY DOES MOVE, and it has to be put back.
        //
        // Posting a mouse event carries a cursor position, and the window server applies it:
        // the fabricated mouse-down at (20_000, 20_000) drags the user's actual pointer
        // off-screen. An earlier version of this file claimed the cursor was never involved.
        // That was wrong, and the diagnostic caught it in an unmistakable way: the first move
        // succeeded, and every move after it failed the `mouseIsMoving` guard, because the
        // pointer had been left off-screen by Stow's own event and the guard correctly saw it
        // somewhere new.
        //
        // So capture where the pointer was, hide it for the duration so the user never sees it
        // jump, and warp it back on every exit path. Ice does the same, for the same reason.
        let cursorBefore = CGEvent(source: nil)?.location
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let cursorBefore { CGWarpMouseCursorPosition(cursorBefore) }
            CGDisplayShowCursor(CGMainDisplayID())
        }

        permitAllEvents()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw Failure.couldNotCreateEvents
        }

        for _ in 0..<maximumAttempts {
            try attempt(windowID: windowID, destination: destination,
                        hostPID: hostPID, source: source)
            if awaitPosition(windowID, at: destination) {
                return Date().timeIntervalSince(began)
            }
        }
        throw Failure.didNotLand(attempts: maximumAttempts)
    }

    /// Whether `windowID` already sits on the requested side of the target.
    static func isPositioned(_ windowID: CGWindowID, at destination: Destination) -> Bool {
        let bar = positionableItems()
        guard let mover = bar.firstIndex(where: { $0.windowNumber == windowID }),
              let target = bar.firstIndex(where: { $0.windowNumber == destination.targetID })
        else { return false }
        switch destination {
        case .leftOf: return mover < target
        case .rightOf: return mover > target
        }
    }

    /// Every menu bar item that is genuinely SITTING in the bar, left to right.
    ///
    /// Uses Stow's own scanner rather than a second window walk, so this and the rest of the
    /// app can never disagree about what is on the bar.
    ///
    /// `isOnScreen` alone is not enough, and relying on it was a real defect. It means the
    /// frame INTERSECTS the bar rect, and an expanded seam does: measured on a live bar, Stow's
    /// own seam spanned x-3862 to x1154 at 5016pt wide, passed the filter, and was then offered
    /// as a neighbour to move an item next to. So an item also has to START inside the bar and
    /// be of plausible item width.
    static func barItems() -> [ObservedItem] {
        guard let screen = NSScreen.main else { return [] }
        let bar = BarScanner.menuBarRect(for: screen)
        return BarScanner.scan(menuBarRect: bar)
            .items
            .filter(\.isOnScreen)
            .filter { $0.frame.minX >= bar.minX }
            .filter { $0.frame.width <= maximumPlausibleItemWidth }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Every item with a window in the menu bar band, unfiltered.
    ///
    /// This is the universe for POSITIONING, and it is deliberately wider than `barItems()`.
    /// `barItems()` answers "what is on the bar, in the order a user sees it", so it drops
    /// anything left of the bar and anything implausibly wide. Both filters are right for that
    /// question and both are fatal to this one.
    ///
    /// Measured, and this is the bug that made temporary reveal do nothing at all: bringing a
    /// tucked item back has to express "right of the tucked seam", and at that moment BOTH ends
    /// of that sentence are excluded from `barItems()`. The item sits at x-3993, left of the bar.
    /// The seam is expanded to 5016pt starting at x-3961, so it fails the width ceiling AND the
    /// left edge, even though its right edge at x1055 is exactly the boundary being aimed at.
    /// The move was refused with "pushed off the visible bar" while a hand-written probe moved
    /// that same window successfully.
    ///
    /// Order is still well defined here: sorting by `minX` puts a pushed-off item leftmost, which
    /// is where it physically is, so a left-of/right-of comparison against it means what it says.
    /// Arrange is unaffected, because arrange rests the seam before it moves anything, and a
    /// rested seam and its on-bar neighbours appear identically in both lists.
    static func positionableItems() -> [ObservedItem] {
        BarScanner.scan(menuBarRect: NSScreen.main.map { BarScanner.menuBarRect(for: $0) } ?? .zero)
            .items
            // REAL items only. `BarScanner` keeps zero-WIDTH windows on purpose, because an item
            // that kept its Y and lost its X extent is the signal the project's hard gate exists
            // to detect, and it says never to restore a width test there. That is right for the
            // gate and wrong here: measured, letting them through put 17 unmatchable placeholders
            // into this list, and since `isPositioned` compares INDICES, the extra entries broke
            // the order check itself and two moves that had physically landed were retried three
            // times and reported as never arriving. Position and width are unfiltered; existence
            // is not.
            .filter { $0.frame.width > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Widest a real menu bar item is taken to be.
    ///
    /// The clock with a date is the widest genuine item measured at 165pt. A seam pushing is
    /// about 5,000pt. Anything between is not something a user recognises as an item, and
    /// nothing should be positioned relative to it.
    private static let maximumPlausibleItemWidth: CGFloat = 400

    // MARK: - one attempt

    private static func attempt(windowID: CGWindowID,
                                destination: Destination,
                                hostPID: pid_t,
                                source: CGEventSource) throws {
        let bar = positionableItems()
        guard let mover = bar.first(where: { $0.windowNumber == windowID }) else {
            // `itemSweptOff` is no longer reachable from here, and that is the point.
            //
            // It used to be the common failure, because the lookup ran against `barItems()` and
            // a swept item is absent from it by construction. Now the lookup runs against the
            // whole band, so a swept item IS found and can be moved back, which is what temporary
            // reveal needs. Reaching this line now genuinely means the window is gone: the owning
            // app quit, or macOS dropped the item entirely because the bar is over budget.
            throw Failure.itemNotOnBar(windowID)
        }
        guard let target = bar.first(where: { $0.windowNumber == destination.targetID }) else {
            throw Failure.targetNotOnBar(destination.targetID)
        }

        // Off-screen on purpose. The location plays no part in TARGETING; the window id fields
        // do that. It is off-screen so the pointer is never left somewhere the user might see.
        let startPoint = CGPoint(x: 20_000, y: 20_000)
        let endX: CGFloat = switch destination {
        case .leftOf: target.frame.minX
        case .rightOf: target.frame.maxX
        }
        let endPoint = CGPoint(x: endX, y: target.frame.midY)

        guard let down = event(.leftMouseDown, at: startPoint, windowID: windowID,
                               pid: hostPID, command: true, source: source),
              let up = event(.leftMouseUp, at: endPoint, windowID: destination.targetID,
                             pid: hostPID, command: false, source: source),
              // Dropped at the mover's own position, so a failed drag puts the item back
              // rather than leaving the window server holding an unfinished one.
              let fallback = event(.leftMouseUp,
                                   at: CGPoint(x: mover.frame.midX, y: mover.frame.midY),
                                   windowID: windowID,
                                   pid: hostPID, command: false, source: source)
        else { throw Failure.couldNotCreateEvents }

        let framesBefore = mover.frame
        guard deliver(down, hostPID: hostPID) else {
            _ = deliver(fallback, hostPID: hostPID)
            throw Failure.couldNotCreateTaps
        }

        // WAIT FOR THE DRAG TO VISIBLY BEGIN before releasing. Sending the up immediately
        // after the down landed about half the time; the item has to be picked up first.
        awaitFrameChange(of: windowID, from: framesBefore, timeout: dragStartTimeout)

        guard deliver(up, hostPID: hostPID) else {
            _ = deliver(fallback, hostPID: hostPID)
            throw Failure.couldNotCreateTaps
        }
    }

    // MARK: - event construction

    private static func event(_ type: CGEventType,
                              at location: CGPoint,
                              windowID: CGWindowID,
                              pid: pid_t,
                              command: Bool,
                              source: CGEventSource) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: location, mouseButton: .left) else {
            return nil
        }
        // Only the mouse-DOWN carries command. A command-held mouse-up is not what a real
        // drag looks like, and the release is what commits the new position.
        e.flags = command ? .maskCommand : []
        e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        e.setIntegerValueField(.eventSourceUserData,
                               value: Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(e))))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                               value: Int64(windowID))
        e.setIntegerValueField(.railWindowID, value: Int64(windowID))
        return e
    }

    /// Lifts the suppression macOS applies to synthetic input, so these events are not
    /// silently dropped for looking automated.
    private static func permitAllEvents() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,
                      .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllRailEvents, state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    // MARK: - the ordering dance

    /// Delivers one event so the hosting process accepts it.
    ///
    /// Posting straight to the session tap does nothing, and posting straight to the process
    /// does nothing. What works: post a NULL event to the process, and when a tap on that
    /// process sees it, post the real event to the session; when a listen-only session tap
    /// sees the real event arrive, hand it to the process. The event has then travelled the
    /// path a physical drag travels.
    private static func deliver(_ event: CGEvent, hostPID: pid_t) -> Bool {
        guard let nullEvent = CGEvent(source: nil) else { return false }
        let nullUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(nullEvent)))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        var delivered = false
        var processTap: EventTap?
        var sessionTap: EventTap?

        processTap = EventTap(pid: hostPID, listenOnly: false, types: [nullEvent.type]) {
            tap, type, received in
            // The system disables a tap that is slow or that the user interrupts. Re-enabling
            // rather than giving up, because the dance is mid-flight.
            if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                tap.enable()
                return
            }
            guard received.getIntegerValueField(.eventSourceUserData) == nullUserData else {
                return
            }
            tap.disable()
            event.post(tap: .cgSessionEventTap)
        }

        sessionTap = EventTap(pid: nil, listenOnly: true, types: [event.type]) {
            tap, type, received in
            if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                tap.enable()
                return
            }
            // Match on the identifiers stamped on the way out, so another app's mouse event
            // of the same type is never mistaken for this one.
            guard received.getIntegerValueField(.railWindowID)
                    == event.getIntegerValueField(.railWindowID),
                  received.getIntegerValueField(.eventSourceUserData)
                    == event.getIntegerValueField(.eventSourceUserData)
            else { return }
            tap.disable()
            event.postToPid(hostPID)
            delivered = true
        }

        guard processTap?.isCreated == true, sessionTap?.isCreated == true else { return false }

        processTap?.enable()
        sessionTap?.enable()
        nullEvent.postToPid(hostPID)

        // Spin the run loop, because the taps deliver through it. Sleeping would starve them.
        let deadline = Date().addingTimeInterval(deliveryTimeout)
        while Date() < deadline, !delivered {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        processTap?.disable()
        sessionTap?.disable()
        return delivered
    }

    // MARK: - waiting

    /// Polls until the item reaches the requested position. ORDER, not frame delta: a move
    /// that was already satisfied changes no frame, and treating that as failure is what made
    /// an earlier measurement report 3s timeouts for moves that had arrived.
    private static func awaitPosition(_ windowID: CGWindowID, at destination: Destination) -> Bool {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if isPositioned(windowID, at: destination) { return true }
        }
        return false
    }

    /// Polls until the item's frame moves at all, which is how the drag announces it began.
    /// Returns regardless on timeout; the caller's own position check is the real verdict.
    private static func awaitFrameChange(of windowID: CGWindowID,
                                         from original: CGRect,
                                         timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            if let now = positionableItems().first(where: { $0.windowNumber == windowID })?.frame,
               now != original {
                return
            }
        }
    }

    // MARK: - tuning

    /// The worst case cost of ONE move attempt, and of one fully-retried move.
    ///
    /// Exposed because `BarArranger` bounds a whole arrange against it and the relationship must not
    /// live only in a comment. The arrange loop was unbounded, and these are the numbers that made
    /// that alarming: a seven-app bar could spin the MAIN run loop for over thirty seconds.
    ///
    /// Derived from the tuning constants below rather than restated, so retuning any of them moves
    /// the budget's own tests rather than silently invalidating them.
    static var worstCaseAttempt: TimeInterval {
        deliveryTimeout * 2 + dragStartTimeout + settleTimeout
    }

    /// One move that exhausts every retry.
    static var worstCaseMove: TimeInterval {
        worstCaseAttempt * TimeInterval(maximumAttempts)
    }

    /// How many times to re-send a drag that did not land.
    ///
    /// A synthesised drag is not guaranteed: the window server can be mid-reflow, or a tap can
    /// be disabled under load. Measured with no retry and no drag-start wait, moves landed
    /// about half the time. Three is enough to absorb that without turning a failure into a
    /// long stall.
    private static let maximumAttempts = 3

    /// How long to wait for one event to complete the ordering dance.
    private static let deliveryTimeout: TimeInterval = 0.5

    /// How long to wait for the drag to visibly begin before releasing the button.
    private static let dragStartTimeout: TimeInterval = 0.15

    /// How long to wait for the bar to settle into the requested order after the release.
    private static let settleTimeout: TimeInterval = 0.6
}

// MARK: - private event plumbing

private extension CGEventField {
    /// Carries a window identifier. Undocumented, with no public constant; Ice uses the same
    /// raw value. This is the field that makes an event address ONE menu bar item.
    static let railWindowID = CGEventField(rawValue: 0x33)!
}

private extension CGEventFilterMask {
    /// There is no single public constant for "permit everything during suppression".
    static let permitAllRailEvents: CGEventFilterMask = [
        .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
    ]
}

/// A CoreGraphics event tap with a Swift closure, scoped to either one process or the session.
///
/// Deliberately minimal. It exists to run the ordering dance in `ItemMover.deliver` and
/// nothing else, so it carries no timeout policy, no labelling and no re-entrancy handling
/// beyond re-enabling after a system disable.
@MainActor
private final class EventTap {
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: (EventTap, CGEventType, CGEvent) -> Void

    /// - Parameter pid: the process to tap, or nil for the session tap.
    init(pid: pid_t?,
         listenOnly: Bool,
         types: [CGEventType],
         handler: @escaping (EventTap, CGEventType, CGEvent) -> Void) {
        self.handler = handler

        let mask: CGEventMask = types.reduce(into: 0) { $0 |= 1 << $1.rawValue }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { tap.handler(tap, type, event) }
            // Returning nil swallows the event. Correct for both taps here: the null event is
            // Stow's own bookkeeping and must never reach anything, and the real event is
            // re-posted deliberately rather than passed through.
            return nil
        }
        let options: CGEventTapOptions = listenOnly ? .listenOnly : .defaultTap

        if let pid {
            machPort = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap,
                                               options: options, eventsOfInterest: mask,
                                               callback: callback, userInfo: context)
        } else {
            machPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                          options: options, eventsOfInterest: mask,
                                          callback: callback, userInfo: context)
        }
        guard let machPort else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(nil, machPort, 0)
    }

    // NO `deinit` TEARDOWN, deliberately. A `@MainActor` class's `deinit` is nonisolated and
    // may only touch Sendable stored properties, and `CFMachPort` is not one. The same
    // constraint already shapes `MenuWidthProbe` and `BarSnapshot.ownerWalk` in this codebase.
    //
    // So teardown is `disable()`'s job, and it invalidates the port rather than merely
    // disabling the tap. `ItemMover.deliver` calls it on every exit path including both
    // failure arms, which is what makes that safe: a tap left enabled would keep swallowing
    // the events it matches for the life of the process.

    var isCreated: Bool { machPort != nil }

    func enable() {
        guard let machPort, let runLoopSource else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    /// Disables the tap AND invalidates its port. Not idempotent-hostile: calling it twice is
    /// harmless, and calling it never leaks a live tap.
    func disable() {
        guard let machPort, let runLoopSource else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CFMachPortInvalidate(machPort)
        self.machPort = nil
        self.runLoopSource = nil
    }
}
