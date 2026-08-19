import Testing
import Foundation
import CoreGraphics
@testable import Stow

// MARK: - BarItemOwners.isPushedOffScreen
//
// Real measured evidence from a 17-item accessibility walk: six apps report the exact
// sentinel `x = -1` with no seam involved at all (LogiTune, HP Secure Print, credential helper,
// command-line helper, automation helper, DisplayLink Manager), and four sit hundreds to thousands of points
// further left (OneDrive x-8958, Vendor Agent x-3934, zoom.us x-3966, Backdrop x-8890), which is
// what a seam pushing ~5,000pt produces. These two clusters must never be confused: only
// the second is a tuckable app Stow itself is hiding.

@Test func theSentinelNegativeOneIsNeverReadAsAPush() {
    #expect(!BarItemOwners.isPushedOffScreen(-1))
}

@Test func everyMeasuredSentinelValueIsNotAPush() {
    // LogiTune, HP Secure Print, several background helpers, DisplayLink Manager: every
    // one of these measured at exactly x-1, and none of them has ever been swept by a
    // Stow seam.
    for x: CGFloat in [-1, -1, -1, -1, -1, -1] {
        #expect(!BarItemOwners.isPushedOffScreen(x))
    }
}

@Test func everyMeasuredPushedOffPositionIsRecognizedAsAPush() {
    // OneDrive, Vendor Agent, zoom.us, Backdrop, in the order the accessibility walk found them.
    let measured: [CGFloat] = [-8958, -3934, -3966, -8890]
    for x in measured {
        #expect(BarItemOwners.isPushedOffScreen(x))
    }
}

@Test func anOrdinaryOnBarPositionIsNotAPush() {
    #expect(!BarItemOwners.isPushedOffScreen(1341))
    #expect(!BarItemOwners.isPushedOffScreen(0))
}

@Test func theThresholdSitsBetweenTheTwoClustersRatherThanAtZero() {
    // The boundary is the smallest magnitude at which "pushed off" and "no position"
    // could ever be confused: one point past the sentinel is already a push, and the
    // sentinel itself never is.
    #expect(BarItemOwners.isPushedOffScreen(-2))
    #expect(!BarItemOwners.isPushedOffScreen(-1))
    #expect(!BarItemOwners.isPushedOffScreen(0))
}

// MARK: - VisibleRowIdentity.cannotBeAddressedIndividually
//
// The blanket `isApple` exclusion predates `ItemMover` being proven against a real
// Apple-owned extra: a live test synthesised the same command-drag `ItemMover` uses
// against the Kerberos extra and it moved, x1153 to x1228. Only Control Center is
// excluded now, and on a different ground entirely: six visible items on this machine
// all share the single bundle id `com.apple.controlcenter`, so bundle-id zoning cannot
// tell them apart, whichever the user meant to move.

@Test func controlCenterCannotBeAddressedIndividuallyBecauseSixItemsShareItsBundleID() {
    #expect(VisibleRowIdentity.cannotBeAddressedIndividually("com.apple.controlcenter"))
}

@Test func kerberosIsAnAppleItemThatCanBeAddressedIndividually() {
    // Proven to move by a live test: x1153 to x1228, the same mechanism ItemMover uses.
    // This is the whole reason the predicate is not "isApple".
    #expect(!VisibleRowIdentity.cannotBeAddressedIndividually("com.apple.KerberosMenuExtra"))
}

@Test func anOrdinaryThirdPartyBundleCanBeAddressedIndividually() {
    #expect(!VisibleRowIdentity.cannotBeAddressedIndividually("com.1password.1password"))
}

@Test func stowsOwnBundleCanBeAddressedIndividually() {
    // This predicate is not what excludes Stow from zoning its own items; every call
    // site pairs it with a separate `bundleID != ownBundle` check. Stow's own bundle is
    // not Control Center, so on this question alone the answer is genuinely false.
    #expect(!VisibleRowIdentity.cannotBeAddressedIndividually("dev.starkpat.stow"))
}

@Test func aNilBundleIDCannotBeAddressedIndividuallyEitherWayNoAnswerBeatsAWrongOne() {
    #expect(!VisibleRowIdentity.cannotBeAddressedIndividually(nil))
}

// MARK: - HideController.candidates
//
// Three sources feed one list: live claims (win over everything, since a remembered
// home goes stale the moment the bar reflows by even one seam's width), remembered
// homes (for an app currently pushed off with no live position), and raw identities
// (for an app Stow has NEVER recorded a home for, because it was already pushed off the
// bar before Stow's first walk, which is exactly OneDrive's situation at x-8958).

private func identity(_ bundle: String, _ axLeftEdge: CGFloat) -> BarItemOwners.Owner {
    BarItemOwners.Owner(name: bundle, bundleID: bundle, pid: 1, axLeftEdge: axLeftEdge)
}

@Test func anAppWithALiveClaimUsesTheLivePositionEvenWhenAHomeIsAlsoKnown() {
    // Measured, the exact failure this precedence exists to prevent: Vendor Agent's stored home
    // read 2028 while the app actually sat at 2045, a 17pt error that decides which side
    // of a seam an app lands on. Live must win.
    let candidates = HideController.candidates(
        identities: [identity("com.example.vendoragent", 2045)],
        liveClaims: [identity("com.example.vendoragent", 2045)],
        homes: ["com.example.vendoragent": 2028],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates == [BarPlan.Candidate(bundleID: "com.example.vendoragent", homeX: 2045,
                                             isPushable: true)])
}

@Test func anAppWithOnlyARememberedHomeFallsBackToItBecauseItHasNoLivePosition() {
    // A pushed-off app has no live claim at all, because `BarItemOwners.claims()` drops
    // anything at a non-positive x. The remembered home is the only position left.
    let candidates = HideController.candidates(
        identities: [identity("com.microsoft.OneDrive", -8958)],
        liveClaims: [],
        homes: ["com.microsoft.OneDrive": 1904],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates == [BarPlan.Candidate(bundleID: "com.microsoft.OneDrive", homeX: 1904,
                                             isPushable: true)])
}

@Test func anAppWithNeitherALiveClaimNorARememberedHomeStillBecomesAZoneableCandidate() {
    // OneDrive's actual situation: pushed off the bar before Stow's first walk ever ran,
    // so it earned no BarHomes entry and has no live claim either. Without the identity
    // walk this app would simply not exist to Stow. It belongs in the list as a
    // candidate that cannot be placed yet, not as a silent omission.
    let candidates = HideController.candidates(
        identities: [identity("com.microsoft.OneDrive", -8958)],
        liveClaims: [],
        homes: [:],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates == [BarPlan.Candidate(bundleID: "com.microsoft.OneDrive", homeX: 0,
                                             isPushable: false)])
}

@Test func aStrandedIdentityReportingTheSentinelIsNotOfferedAsACandidate() {
    // x-1 names "no position", not a push. Offering it would zone an item Stow never
    // actually saw sitting anywhere.
    let candidates = HideController.candidates(
        identities: [identity("com.logitech.logitune", -1)],
        liveClaims: [],
        homes: [:],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates.isEmpty)
}

@Test func stowsOwnBundleIsExcludedFromEveryCandidateSource() {
    let candidates = HideController.candidates(
        identities: [identity("dev.starkpat.stow", -3800)],
        liveClaims: [identity("dev.starkpat.stow", 2318)],
        homes: ["dev.starkpat.stow": 2318],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates.isEmpty)
}

@Test func controlCenterIsExcludedFromEveryCandidateSourceBecauseItCannotBeAddressedIndividually() {
    let candidates = HideController.candidates(
        identities: [identity("com.apple.controlcenter", -3800)],
        liveClaims: [identity("com.apple.controlcenter", 1804)],
        homes: ["com.apple.controlcenter": 1804],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates.isEmpty)
}

@Test func kerberosParticipatesAsAnOrdinaryCandidateNowThatItCanBeAddressedIndividually() {
    // The concrete Cause 2 fix: an Apple-owned, individually addressable extra is no
    // longer filtered out purely for being Apple's.
    let candidates = HideController.candidates(
        identities: [identity("com.apple.KerberosMenuExtra", 1160)],
        liveClaims: [identity("com.apple.KerberosMenuExtra", 1160)],
        homes: [:],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates == [BarPlan.Candidate(bundleID: "com.apple.KerberosMenuExtra",
                                             homeX: 1160, isPushable: true)])
}

@Test func threeKindsOfAppCoexistInOneCandidateListSortedRightToLeft() {
    // Live, remembered-only, and stranded, together, the same shape currentCandidates()
    // produces from the real bar. Sorted rightmost first, as every other candidate list
    // in this codebase is.
    let candidates = HideController.candidates(
        identities: [identity("com.1password.1password", 1341),
                    identity("com.example.vendoragent", -3934),
                    identity("com.microsoft.OneDrive", -8958)],
        liveClaims: [identity("com.1password.1password", 1341)],
        homes: ["com.example.vendoragent": 2028],
        ownBundle: "dev.starkpat.stow")
    #expect(candidates == [
        BarPlan.Candidate(bundleID: "com.example.vendoragent", homeX: 2028, isPushable: true),
        BarPlan.Candidate(bundleID: "com.1password.1password", homeX: 1341, isPushable: true),
        BarPlan.Candidate(bundleID: "com.microsoft.OneDrive", homeX: 0, isPushable: false),
    ])
}
