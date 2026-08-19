import AppKit
import Testing
@testable import Stow

// Tests for the invariants the pre-CR review established. Each one pins a specific defect the
// reviewers found, so a regression fails here rather than being rediscovered on a real bar.

// MARK: - the arrange budget

// The budget exists because the move loop was unbounded: `ItemMover` allows three attempts at up to
// 1.75s each, so one stubborn item costs 5.25s and a seven-app bar could spin the main run loop for
// 36s. What matters is not the number 3.0 but its RELATIONSHIP to what one move can cost, and that
// relationship is what breaks silently if someone retunes the mover.

@Test @MainActor func theArrangeBudgetAllowsAtLeastOneCompleteMoveAttempt() {
    #expect(BarArranger.totalBudget >= ItemMover.worstCaseAttempt,
            "a budget below one attempt would abandon the first app before it could ever land")
}

@Test @MainActor func theEnforcedCeilingStaysInsideWhatAUserWillWaitFor() {
    // Pins the bound that is ACTUALLY enforced, not the constant. The budget guard sits at the top
    // of the move loop, so the last move can start just inside it and then run to its own worst
    // case; the real ceiling is therefore `totalBudget + worstCaseMove`.
    //
    // The first version of this test asserted `totalBudget < worstCaseMove * 2` and would have
    // passed at a budget of 10s, which defends nothing. Ten seconds is the outer edge of a stall a
    // user will read as a hang rather than a crash, and it is what this holds the whole move phase
    // to.
    #expect(BarArranger.enforcedCeiling <= 10.0,
            "a move phase that can block the main actor past ten seconds reads as a hang")
}

@Test @MainActor func theEnforcedCeilingIsTheBudgetPlusOneFullyRetriedMove() {
    // The relationship itself, so retuning either constant cannot silently break the reasoning the
    // budget's doc comment depends on.
    #expect(BarArranger.enforcedCeiling == BarArranger.totalBudget + ItemMover.worstCaseMove)
    #expect(ItemMover.worstCaseMove > ItemMover.worstCaseAttempt,
            "a retried move must cost more than a single attempt, or the retry does nothing")
}

// MARK: - the zoning predicate, and the split it used to have

// The engine and the Arrange board built two candidate lists with two different Apple predicates, so
// an item the arranger could move was never offered a tile. These pin the predicate itself; the list
// convergence is covered by the candidate tests below.

@Test func onlyControlCenterCannotBeAddressedIndividually() {
    // Control Center is excluded because its six visible items share ONE bundle id, and the bundle
    // id is the zoning key, so they could only ever move as a block.
    #expect(VisibleRowIdentity.cannotBeAddressedIndividually("com.apple.controlcenter"))
    // Every other Apple bundle is addressable. Measured: the Kerberos extra moved x1153 to x1228
    // under the same synthesised drag `ItemMover` uses.
    #expect(VisibleRowIdentity.cannotBeAddressedIndividually("com.apple.KerberosMenuExtra") == false)
    #expect(VisibleRowIdentity.cannotBeAddressedIndividually("com.microsoft.OneDrive") == false)
}

@Test func theTwoApplePredicatesAgree() {
    // `StatusPanel.VisibleRow.isAppleBundle` forwards to `VisibleRowIdentity.isApple` rather than
    // repeating the prefix test, because the two were added in the same change as two copies. This
    // fails if either grows its own answer.
    for bundle in ["com.apple.controlcenter", "com.apple.KerberosMenuExtra",
                   "com.microsoft.OneDrive", "dev.starkpat.stow", ""] {
        #expect(StatusPanel.VisibleRow.isAppleBundle(bundle) == VisibleRowIdentity.isApple(bundle),
                "the two Apple predicates disagreed on \(bundle)")
    }
}

// MARK: - the candidate list the board now shares with the engine

// `MainWindow.candidateApps()` is private and needs a live bar, so it cannot be driven here. What it
// now DELEGATES to can be, and that is the point of the change: the board's list is the engine's
// list, so these tests cover both surfaces where they used to cover only one.

@Test func anIndividuallyAddressableAppleItemIsAnOrdinaryCandidate() {
    let owner = BarItemOwners.Owner(name: "KerberosMenuExtra",
                                    bundleID: "com.apple.KerberosMenuExtra",
                                    pid: 1, axLeftEdge: 1205)
    let candidates = HideController.candidates(identities: [owner],
                                               liveClaims: [owner],
                                               homes: [:],
                                               ownBundle: "dev.starkpat.stow")
    #expect(candidates.contains { $0.bundleID == "com.apple.KerberosMenuExtra" },
            "the lock must be offerable, since the arranger can move it")
}

@Test func controlCenterIsNotACandidateEvenWhenItIsOnTheBar() {
    let owner = BarItemOwners.Owner(name: "Clock", bundleID: "com.apple.controlcenter",
                                    pid: 2, axLeftEdge: 1573)
    let candidates = HideController.candidates(identities: [owner],
                                               liveClaims: [owner],
                                               homes: [:],
                                               ownBundle: "dev.starkpat.stow")
    #expect(candidates.isEmpty, "six items behind one bundle id cannot be zoned individually")
}

@Test func stowsOwnItemsAreNeverCandidates() {
    // The seam IS the boundary and the token is deliberately outside it, so offering either would
    // let the user zone the machinery doing the zoning.
    let own = BarItemOwners.Owner(name: "Stow", bundleID: "dev.starkpat.stow",
                                   pid: 3, axLeftEdge: 1450)
    let candidates = HideController.candidates(identities: [own],
                                               liveClaims: [own],
                                               homes: ["dev.starkpat.stow": 1450],
                                               ownBundle: "dev.starkpat.stow")
    #expect(candidates.isEmpty)
}

// MARK: - claims as a filter over identities

// `claims()` was 27 lines of accessibility walk copied from `identities()` with one predicate
// changed. It is now the filter it always was. Both need a live AX tree, so what is testable here is
// the predicate that expresses the relationship.

@Test func theOffScreenPredicateSeparatesASentinelFromARealPosition() {
    // Measured across 17 items: six report exactly x = -1, a sentinel meaning "no position", while
    // four sit hundreds to thousands of points left, which is a real position off the visible bar.
    #expect(BarItemOwners.isPushedOffScreen(-8958))
    #expect(BarItemOwners.isPushedOffScreen(-3934))
    #expect(BarItemOwners.isPushedOffScreen(-1) == false)
    #expect(BarItemOwners.isPushedOffScreen(1205) == false)
}

// MARK: - the reveal state machine

// `RevealCoordinator`'s move path needs a real bar, so what is testable is the DECISION that governs
// whether a previously revealed item gets put back at all. That decision is where the leak lived: a
// second reveal overwrote the state that named the first item, so a failed retuck forgot it.

@Test func revealingASecondItemDecidesToPutTheFirstBack() {
    let step = RevealCoordinator.NextStep.decide(currentlyRevealed: "us.zoom.xos",
                                                 requesting: "com.microsoft.Outlook")
    #expect(step == .tuckThenRevealFresh(previous: "us.zoom.xos"),
            "the first item must be named, or nothing can hold it when its retuck fails")
}

@Test func revealingTheSameItemRestartsItsTimerRatherThanMovingItAgain() {
    let step = RevealCoordinator.NextStep.decide(currentlyRevealed: "us.zoom.xos",
                                                 requesting: "us.zoom.xos")
    #expect(step == .restartTimer)
}

@Test func revealingWithNothingOutIsAFreshReveal() {
    #expect(RevealCoordinator.NextStep.decide(currentlyRevealed: nil,
                                              requesting: "us.zoom.xos") == .revealFresh)
}

// MARK: - the drain budget

// `drainPendingRetucks` retries held retucks synchronously on the main actor, each costing up to a
// full `ItemMover.worstCaseMove`. Its budget shipped at 6.0s, ABOVE that 5.25s cost, so after one
// full-cost retry the guard still passed and a second started: 10.5s inside a click, which is the
// opposite of what the constant's own comment claimed it delivered. These pin the relationship that
// makes "one retry per drain" true, rather than pinning the number.

@Test @MainActor func aDrainCannotStartASecondRetryAfterAFullCostFirstOne() {
    #expect(RevealCoordinator.drainBudget <= ItemMover.worstCaseMove,
            "a budget above one fully-retried move lets a second retry start and doubles the stall")
}

@Test @MainActor func theDrainIsBoundedNoLooserThanAnArrange() {
    // Both are promises about how long the main actor may be held, and the drain's is made inside a
    // click while the arrange's is not, so the drain must not be the more generous of the two.
    #expect(RevealCoordinator.drainBudget <= BarArranger.totalBudget)
}

// MARK: - the hides-anything predicate

// This was written out by hand in two switch statements that must agree: the arrange's success ending
// and its failure ending. They were identical and nothing stopped them drifting, and drift there
// silently reintroduces a real bug, a failed arrange that leaves every tucked app on show. It is one
// accessor now, so these pin its meaning rather than its spelling.

@Test func noZonesMeansNothingIsHidden() {
    #expect(Config.default.hidesAnything == false)
    var cfg = Config.default
    cfg.zoneByBundleID = [:]
    #expect(cfg.hidesAnything == false)
}

@Test func anAppPinnedExplicitlyStillHidesNothing() {
    // `.pinned` is the default for an unassigned app, so an explicit pin must not read as a request
    // to hide. Getting this backwards would make every arrange end by expanding the seam.
    var cfg = Config.default
    cfg.zoneByBundleID = ["us.zoom.xos": .pinned]
    #expect(cfg.hidesAnything == false)
}

@Test func aTuckedAppMeansSomethingIsHidden() {
    var tucked = Config.default
    tucked.zoneByBundleID = ["us.zoom.xos": .tucked]
    #expect(tucked.hidesAnything)

    // Mixed, which is the ordinary real case: one pinned app must not mask a tucked one.
    var mixed = Config.default
    mixed.zoneByBundleID = ["dev.starkpat.authbar": .pinned, "us.zoom.xos": .tucked]
    #expect(mixed.hidesAnything)
}
