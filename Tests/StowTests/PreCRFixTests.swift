import AppKit
import Testing
@testable import Stow

// Tests for the invariants the pre-CR review established. Each one pins a specific defect the
// reviewers found, so a regression fails here rather than being rediscovered on a real bar.

// MARK: - the zoning predicate, and the split it used to have

// The engine and the Arrange board built two candidate lists with two different Apple predicates, so
// an item the arranger could move was never offered a tile. These pin the predicate itself; the list
// convergence is covered by the candidate tests below.

@Test func onlyControlCenterCannotBeAddressedIndividually() {
    // Control Center is excluded because its six visible items share ONE bundle id, and the bundle
    // id is the zoning key, so they could only ever move as a block.
    #expect(VisibleRowIdentity.cannotBeAddressedIndividually("com.apple.controlcenter"))
    // Every other Apple bundle is addressable, so it can sit on either side of the boundary.
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
            "the lock must be listed, since the user can drag it across the boundary")
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

// `RevealCoordinator` changes only the boundary's width now, but the DECISION about a reveal that
// arrives while another is out is still pure and still logged, so it stays pinned.

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

// MARK: - the hides-anything predicate

// One accessor, so these pin its meaning rather than its spelling.

@Test func noZonesMeansNothingIsHidden() {
    #expect(Config.default.hidesAnything == false)
    var cfg = Config.default
    cfg.zoneByBundleID = [:]
    #expect(cfg.hidesAnything == false)
}

@Test func anAppPinnedExplicitlyStillHidesNothing() {
    // `.pinned` is the default for an unassigned app, so an explicit pin must not read as a request
    // to hide.
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
