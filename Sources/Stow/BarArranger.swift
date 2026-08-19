import AppKit

/// Arranges the bar by moving APPS to the correct side of a seam that stays put.
///
/// The inverse of `HideController.moveCut`, and the reason it exists is measured. Moving the
/// seam means destroying and recreating a status item, because macOS reads
/// `NSStatusItem Preferred Position` only at creation; the preference names a coarse SLOT
/// rather than a pixel, so finding the right one takes a five-probe bisection; and an apply
/// runs two of those. Measured by `--probecost` and `--drag`: 0.415s per reposition, about ten
/// per drag, 5.6s for a drop. Three attempts to cut the probe count all failed their
/// correctness gate, because the bisection's habit of picking the LEFTMOST qualifying slot is
/// what keeps pinned apps on the bar.
///
/// This removes the search rather than tuning it. The seam never moves, so there is no slot to
/// find. Each app that is on the wrong side gets moved across, at a measured 0.2-1.0s, and an
/// app already on the correct side costs nothing.
///
/// It also deletes COLLATERAL. A seam sweeps everything to its left, so placing one to hide an
/// app inevitably hides that app's neighbours: the pane has two warning banners about exactly
/// that, and on the built-in display, hiding `com.microsoft.Outlook` at x1113 required a slot
/// at x1217 and took `com.example.vendoragent` at x1181 with it. When the seam holds still and apps
/// move around it, nothing is swept by accident and neither warning has anything to report.
///
/// WHAT THIS CANNOT DO. It moves items, so it needs every item's window id, and a window
/// number is not stable: Control Center recreates an item's window and the number changes
/// underneath, measured mid-run as win55245 becoming win65229. So the mapping from a persisted
/// zone to a live window is resolved fresh on every arrange, never stored.
@MainActor
enum BarArranger {
    private struct ExpectedPosition {
        let bundleID: String
        let windowID: CGWindowID
        let wantsRight: Bool
    }

    /// What one arrange did, for the caller to report or act on.
    struct Outcome {
        struct Failure {
            let bundleID: String?
            let reason: String
            let recovery: String

            func userMessage(displayName: (String) -> String) -> String {
                let subject = bundleID.map(displayName) ?? "Stow"
                return "\(subject): \(reason) \(recovery)"
            }
        }

        /// Apps moved across the seam, by bundle identifier.
        var moved: [String] = []
        /// Apps already on the correct side, so nothing was spent on them.
        var alreadyCorrect: [String] = []
        /// Apps that should have moved and did not, with why.
        var failed: [Failure] = []
        /// True when completed moves were reversed because the transaction did not verify.
        var rolledBack = false
        /// Total time in the moves themselves.
        var cost: TimeInterval = 0

        var isClean: Bool { failed.isEmpty }
    }

    /// Puts every app on the side of the tucked seam its zone requires.
    ///
    /// - Parameters:
    ///   - config: the user's zones. Read, never written.
    ///   - seamWindow: returns the seam's CURRENT window number, re-read for every move.
    ///
    ///     A closure rather than a value, because a seam's window number is not stable:
    ///     repositioning destroys and recreates the item, and Control Center recreates item
    ///     windows around a move anyway. Passing a number captured once produced "the seam is no
    ///     longer identifiable" for three consecutive apps in one launch arrange, which then left
    ///     `us.zoom.xos` visible while it was tucked.
    ///
    ///     The arrangement is expressed relative to
    ///     THIS, which is what makes the seam's position irrelevant: it can sit anywhere and the
    ///     zones still hold.
    ///
    /// Works with the seams at rest OR expanded, which it did not used to.
    ///
    /// The old contract was "MUST be called with every seam at REST", because a pushing seam is
    /// about 5,000pt wide and `ItemMover.barItems()` rejects both it and anything it has swept
    /// off, so an expanded seam could not be found and a leftward-moved app could not be
    /// verified. That contract could not be honoured: `awaitBarToSettle` and `awaitMeasuredWidth`
    /// both spin the run loop, which lets other queued main-actor work run underneath an arrange,
    /// and measured at launch the entry guard passed with a rested seam and then EVERY move
    /// failed on "the seam has no live window" because it had expanded in between.
    ///
    /// Resolving through `ItemMover.positionableItems()` removes the requirement instead of
    /// restating it. An expanded seam is found, and both directions still mean the right thing:
    /// `.rightOf` aims at its right edge, which is the visible boundary, and `.leftOf` at its
    /// left edge, which is inside the hidden run. Ordering by `minX` also stays honest, since a
    /// swept item really is leftmost.
    static func arrange(config: Config, seamWindow: () -> CGWindowID?) -> Outcome {
        var outcome = Outcome()
        let began = Date()

        let items = ItemMover.positionableItems()
        guard let seamWindowID = seamWindow() else {
            outcome.failed.append(Outcome.Failure(
                bundleID: nil,
                reason: "the menu-bar boundary is not ready.",
                recovery: "Choose Show Everything, then try again."))
            return outcome
        }
        guard let seamIndex = items.firstIndex(where: { $0.windowNumber == seamWindowID }) else {
            // Say WHY, with the evidence. "Not on the visible bar" alone sent two rounds of
            // guessing at a seam that was demonstrably present, because the message could not
            // distinguish "the scan never saw this window" from "the scan saw it and a filter
            // in `ItemMover.barItems` rejected it".
            let unfiltered = NSScreen.main.map {
                BarScanner.scan(menuBarRect: BarScanner.menuBarRect(for: $0)).items
            } ?? []
            let seamInScan = unfiltered.first { $0.windowNumber == seamWindowID }
            let detail: String
            if let seamInScan {
                detail = "the scan DID see win\(seamWindowID) at"
                       + " x\(Int(seamInScan.frame.minX)) w\(Int(seamInScan.frame.width))"
                       + " onScreen=\(seamInScan.isOnScreen), so a filter in barItems rejected it"
            } else {
                detail = "the scan did not see win\(seamWindowID) at all;"
                       + " it returned \(unfiltered.count) window(s) at bar level"
            }
            outcome.failed.append(Outcome.Failure(
                bundleID: nil,
                reason: "the menu-bar boundary could not be verified (\(detail)).",
                recovery: "Choose Show Everything, then try again."))
            return outcome
        }

        // REFUSE if identity cannot be resolved, rather than reporting a clean no-op.
        //
        // `BarItemOwners.claims()` returns an EMPTY array without an Accessibility grant, and
        // every loop below is keyed on resolving an owner. So an untrusted process skipped every
        // item, moved nothing, recorded no failures, and reported success. That is the worst
        // possible shape for a bug: the arrange said it worked, the apps stayed where they were,
        // and the seam then hid whatever happened to be on the wrong side.
        //
        // It is a real condition, not a hypothetical. The diagnostics run from a terminal and
        // inherit ITS grant, so they work while the app itself has none. Measured: that trap cost
        // twenty minutes once already.
        guard PressActionProbe.isTrusted else {
            outcome.failed.append(Outcome.Failure(
                bundleID: nil,
                reason: "Accessibility access is off, so apps cannot be moved safely.",
                recovery: "Enable Stow in System Settings > Privacy & Security > Accessibility."))
            return outcome
        }

        // Resolve bundle identifiers to LIVE window ids, once. Two reasons this is done here
        // rather than per app: the owner walk costs a measured 0.965s, and resolving twice
        // during one arrange could see two different bars.
        let claims = BarItemOwners.refreshCache()
        let ownBundle = Bundle.main.bundleIdentifier

        guard !claims.isEmpty else {
            outcome.failed.append(Outcome.Failure(
                bundleID: nil,
                reason: "no menu-bar apps could be identified.",
                recovery: "Choose Show Everything, reopen Arrange, and try again."))
            return outcome
        }

        // RESOLVE bundle -> window ONCE, and carry the window id through the whole pass.
        //
        // This loop used to re-resolve every item immediately before its own move, on the stated
        // grounds that "moving one item makes Control Center recreate item windows, and the numbers
        // change underneath". That was tested directly and it is false: moving one item and diffing
        // the bar-level window ids before and after showed NONE vanished and NONE appeared, only
        // the order changed. The id is stable; what moved was the item.
        //
        // The false premise was expensive, because re-resolving means matching an accessibility
        // left edge to a window x within 10pt, and the accessibility tree LAGS the window server.
        // `ItemMover.move` waits for the window server only, so the next item in the same pass was
        // matched against stale coordinates. Measured, that is the cause of every "no longer on the
        // visible bar when its turn came" failure in this bar's logs: zoom.us sat plainly at x1055
        // and could not be found, because the walk still described where it had been before an
        // earlier move in the same arrange shifted it.
        //
        // Resolving once removes the dependency on accessibility freshness entirely, and it also
        // removes an owner walk per move, which cost about 0.26s each.
        //
        var toMove: [(bundleID: String, windowID: CGWindowID, hostPID: pid_t, wantsRight: Bool)] = []
        var expectations: [ExpectedPosition] = []
        var unresolved = 0

        // A TOTAL BUDGET, because there was none and the arithmetic was alarming.
        //
        // One move's worst case is 1.75s: a 0.5s delivery wait for the mouse-down, 0.15s for the
        // drag to be picked up, 0.5s for the mouse-up, then a 0.6s settle. `ItemMover` retries
        // three times, so 5.25s per item, and `toMove` is every third-party item on the wrong side
        // with no bound. A seven-app bar is 36s, and the caller's entry costs add roughly nine
        // more. All of it spent spinning the MAIN run loop, in the same change that reports
        // sub-second arranges.
        //
        // The budget is generous against the measured 0.46-0.79s so a slow-but-working bar still
        // completes, and it is small enough that a pathological one gives the main actor back. An
        // abandoned app is REPORTED, not skipped: a partial arrange that claims success is the
        // failure mode this whole file has been fighting.
        let deadline = Date().addingTimeInterval(totalBudget)
        var abandoned: [String] = []
        for (index, item) in items.enumerated() {
            guard index != seamIndex else { continue }
            // COUNT the unresolvable rather than skipping them in silence.
            //
            // An item whose owner cannot be matched is invisible to every decision below, so a
            // bare `continue` here let an arrange report "5 correct, 0 failed" while `us.zoom.xos`
            // sat visible on the wrong side. The arrange had never seen it. A count is the
            // difference between "everything is right" and "everything I could see is right".
            guard let owner = item.owner(in: claims) else {
                unresolved += 1
                continue
            }
            guard !VisibleRowIdentity.cannotBeAddressedIndividually(owner.bundleID),
                  owner.bundleID != ownBundle else { continue }

            let wantsRight = config.zone(forBundleID: owner.bundleID) == .pinned
            expectations.append(ExpectedPosition(
                bundleID: owner.bundleID,
                windowID: item.windowNumber,
                wantsRight: wantsRight))
            if wantsRight == (index > seamIndex) {
                outcome.alreadyCorrect.append(owner.bundleID)
            } else {
                toMove.append((owner.bundleID, item.windowNumber, item.ownerPID, wantsRight))
            }
        }

        var completed: [(bundleID: String, windowID: CGWindowID,
                         hostPID: pid_t, originalWantsRight: Bool)] = []
        for (bundleID, windowID, hostPID, wantsRight) in toMove {
            guard Date() < deadline else {
                abandoned.append(bundleID)
                continue
            }
            // The SEAM is still re-read every time, and only the seam.
            //
            // Not for symmetry with the old code: the seam genuinely is recreated, because
            // changing a status item's placement destroys and rebuilds it, so its window number
            // really does change underneath an arrange. That is why the caller hands over a
            // closure rather than a number. The items being moved are not recreated, which the
            // id-stability test above settles, so they need no such treatment.
            guard let liveSeamID = seamWindow() else {
                outcome.failed.append(Outcome.Failure(
                    bundleID: bundleID,
                    reason: "the Stow boundary disappeared during the move.",
                    recovery: "Choose Show Everything, then try again."))
                continue
            }

            let destination: ItemMover.Destination = wantsRight
                ? .rightOf(liveSeamID)
                : .leftOf(liveSeamID)
            do {
                try ItemMover.move(windowID: windowID,
                                   to: destination,
                                   hostPID: hostPID)
                outcome.moved.append(bundleID)
                completed.append((bundleID, windowID, hostPID, !wantsRight))
            } catch {
                outcome.failed.append(Outcome.Failure(
                    bundleID: bundleID,
                    reason: friendlyMoveReason(error),
                    recovery: "Try again; if it repeats, Command-drag that icon across Stow."))
            }
        }

        // An unresolved item is not a clean arrange. Saying so is what stops a silent skip being
        // read as success, which is exactly how a tucked app stayed visible with nothing reported.
        if unresolved > 0 {
            outcome.failed.append(Outcome.Failure(
                bundleID: nil,
                reason: "\(unresolved) menu-bar item(s) could not be identified, so the result"
                    + " could not be verified.",
                recovery: "Choose Show Everything and reopen Arrange."))
        }
        for bundleID in abandoned {
            outcome.failed.append(Outcome.Failure(
                bundleID: bundleID,
                reason: "the move took longer than Stow's \(Int(totalBudget))-second safety budget.",
                recovery: "Try again after the menu bar settles."))
        }

        if outcome.failed.isEmpty {
            let verification = verificationFailures(
                expectations: expectations,
                seamWindow: seamWindow)
            outcome.failed.append(contentsOf: verification)
        }

        // A transaction is all-or-nothing. If any move or fresh verification failed, put every
        // app already moved back on its original side before the caller is allowed to hide.
        if !outcome.failed.isEmpty, !completed.isEmpty {
            for move in completed.reversed() {
                guard let liveSeamID = seamWindow() else {
                    outcome.failed.append(Outcome.Failure(
                        bundleID: move.bundleID,
                        reason: "Stow could not restore this app because its boundary disappeared.",
                        recovery: "Use Show Everything and Command-drag the icon back if needed."))
                    continue
                }
                let destination: ItemMover.Destination = move.originalWantsRight
                    ? .rightOf(liveSeamID)
                    : .leftOf(liveSeamID)
                do {
                    try ItemMover.move(windowID: move.windowID,
                                       to: destination,
                                       hostPID: move.hostPID)
                } catch {
                    outcome.failed.append(Outcome.Failure(
                        bundleID: move.bundleID,
                        reason: "automatic rollback was refused by macOS.",
                        recovery: "Use Show Everything and Command-drag the icon back if needed."))
                }
            }
            outcome.rolledBack = true
            outcome.moved.removeAll()
        }

        outcome.cost = Date().timeIntervalSince(began)
        return outcome
    }

    private static func verificationFailures(
        expectations: [ExpectedPosition],
        seamWindow: () -> CGWindowID?
    ) -> [Outcome.Failure] {
        let items = ItemMover.positionableItems()
        guard let seamID = seamWindow(),
              let seamIndex = items.firstIndex(where: { $0.windowNumber == seamID }) else {
            return [Outcome.Failure(
                bundleID: nil,
                reason: "the final menu-bar layout could not be verified.",
                recovery: "Choose Show Everything, then try again.")]
        }
        var failures: [Outcome.Failure] = []
        for expectation in expectations {
            guard let index = items.firstIndex(where: {
                $0.windowNumber == expectation.windowID
            }) else {
                failures.append(Outcome.Failure(
                    bundleID: expectation.bundleID,
                    reason: "its menu-bar item disappeared during verification.",
                    recovery: "Stow restored the previous layout; try again."))
                continue
            }
            guard expectation.wantsRight != (index > seamIndex) else { continue }
            failures.append(Outcome.Failure(
                bundleID: expectation.bundleID,
                reason: expectation.wantsRight
                    ? "it did not return to the visible side."
                    : "it did not reach In Stow.",
                recovery: "Stow restored the previous layout; try again."))
        }
        return failures
    }

    private static func friendlyMoveReason(_ error: Error) -> String {
        guard let failure = error as? ItemMover.Failure else {
            return "macOS refused the move."
        }
        switch failure {
        case .noAccessibility:
            return "Accessibility access is off."
        case .modifiersHeld:
            return "a modifier key is currently held."
        case .mouseButtonHeld:
            return "a mouse drag is currently in progress."
        case .didNotLand:
            return "macOS did not place the icon on the requested side."
        default:
            return "the icon was not available to move."
        }
    }

    /// How late a NEW move may START. Not a bound on the whole arrange, and the difference matters.
    ///
    /// The guard sits at the top of the move loop, so a move that begins one millisecond inside the
    /// budget still runs to completion: nothing interrupts `ItemMover.move` once it is in flight, and
    /// it retries internally. So the real ceiling on the move phase is this plus one fully-retried
    /// move, `totalBudget + ItemMover.worstCaseMove`, which is 8.25s with the current tuning rather
    /// than the 3.0s a reading of "how long an arrange may spend" would suggest. An earlier version
    /// of this comment claimed the latter, which understated the bound by 5.25s.
    ///
    /// Bounding the start is still worth having, because the thing being prevented is UNBOUNDED
    /// growth with the number of items: before it, every app on the wrong side could contribute
    /// 5.25s, so a seven-app bar could spin the MAIN run loop for over thirty seconds in the same
    /// change that reports sub-second arranges. Interrupting a move in flight would mean threading a
    /// deadline through `ItemMover` and abandoning a synthesised drag half-delivered, which trades a
    /// bounded stall for a bar in an unknown state.
    ///
    /// Three seconds is above one complete attempt, so the first app is never abandoned before it
    /// could land, and it leaves roughly four times the measured 0.79s worst case for an arrange
    /// that is simply doing its job. `enforcedCeiling` is the honest number for this phase, and it
    /// says what it still excludes.
    static let totalBudget: TimeInterval = 3.0

    /// The worst case for the MOVE PHASE only. Not for an arrange as a user experiences it.
    ///
    /// The last move may start just inside the budget and then run to its own worst case, so this is
    /// `totalBudget + ItemMover.worstCaseMove`. Exposed so the tests can pin the bound that is
    /// actually enforced rather than the constant that is easy to assert: asserting `totalBudget`
    /// alone passes at any value, which is what made the first pair of budget tests too loose to
    /// defend anything.
    ///
    /// WHAT THIS DOES NOT COVER, stated because the previous two versions of this reasoning both
    /// understated the total. `HideController.arrangeByMovingItems` does its entry work before
    /// calling here, and none of it is bounded by this: `awaitMeasuredWidth` can take 3.0s,
    /// `awaitBarToSettle` 1.5s, and a seam reposition adds another `awaitMeasuredWidth`. So the
    /// figure a user could feel is roughly that entry work plus this, and bounding it properly means
    /// giving the caller its own budget rather than renaming this one.
    @MainActor
    static var enforcedCeiling: TimeInterval { totalBudget + ItemMover.worstCaseMove }

    /// Appends one line about an arrange to `~/Library/Logs/Stow/arrange.log`.
    ///
    /// The live app has no other voice. Everything learned about arranging so far came from a
    /// diagnostic run in a terminal, and a terminal-launched process inherits the TERMINAL's
    /// Accessibility grant, so it succeeds in conditions the app itself may not share. Every
    /// wiring bug in this change was invisible for exactly that reason: the diagnostic reported
    /// 0 of 7 wrong while the shipped app was sweeping five pinned apps off the bar.
    ///
    /// Deliberately a plain file rather than `os_log`: it survives the process, it needs no
    /// predicate to read, and a user can be asked to paste it.
    static func log(_ outcome: Outcome, context: String) {
        append("\(context)"
               + "  moved=\(outcome.moved.joined(separator: ","))"
               + "  correct=\(outcome.alreadyCorrect.count)"
               + "  failed=\(outcome.failed.map { "\($0.bundleID ?? "-")(\($0.reason))" }.joined(separator: "; "))"
               + "  rolledBack=\(outcome.rolledBack)"
               + "  cost=\(String(format: "%.2f", outcome.cost))s")
    }

    /// Appends one timestamped line to the log, and OWNS the file.
    ///
    /// Split out because the reveal path had its own copy of the directory, the filename and the
    /// append-or-create dance. One file with two writers is exactly where the write mechanism must
    /// not be duplicated: the single-file property `RevealCoordinator` relies on, so that a reveal
    /// between two arranges reads in order, was being held by two implementations happening to
    /// agree, including both remembering to terminate their own line. The newline is added here now,
    /// so a caller cannot forget it.
    ///
    /// Failure is ignored on purpose: a diagnostic log that can break the thing it observes is
    /// worse than no log.
    nonisolated static func append(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Stow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("arrange.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Whether every app is already on the side its zone requires.
    ///
    /// Cheap: one scan and one cached-claims read, no moves. Lets a caller skip an arrange
    /// entirely, which is the common case when a drag changed a zone that was already satisfied.
    static func isArranged(config: Config, seamWindow: () -> CGWindowID?) -> Bool {
        let items = ItemMover.positionableItems()
        guard let seamWindowID = seamWindow(),
              let seamIndex = items.firstIndex(where: { $0.windowNumber == seamWindowID })
        else { return false }
        let claims = BarItemOwners.lastKnownClaims
        let ownBundle = Bundle.main.bundleIdentifier

        for (index, item) in items.enumerated() where index != seamIndex {
            guard let owner = item.owner(in: claims) else { continue }
            guard !VisibleRowIdentity.cannotBeAddressedIndividually(owner.bundleID),
                  owner.bundleID != ownBundle else { continue }
            let wantsRight = config.zone(forBundleID: owner.bundleID) == .pinned
            if wantsRight != (index > seamIndex) { return false }
        }
        return true
    }
}
