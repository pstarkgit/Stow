import Testing
import Foundation
import CoreGraphics
@testable import Stow

@Test @MainActor func sentinelOwnerResolvesToTheOnlyUnclaimedHiddenWindow() {
    let acme = BarItemOwners.Owner(name: "ACME", bundleID: "com.amazon.ACME",
                                   pid: 4050, axLeftEdge: -1)
    let chatGPT = BarItemOwners.Owner(name: "ChatGPT", bundleID: "com.openai.codex",
                                      pid: 6683, axLeftEdge: -3967)
    let items = [
        ObservedItem(windowNumber: 6683, ownerPID: 1, bundleID: nil,
                     ownerName: "Control Center",
                     frame: CGRect(x: -3968, y: 0, width: 38, height: 33),
                     isOnScreen: false),
        ObservedItem(windowNumber: 155, ownerPID: 1, bundleID: nil,
                     ownerName: "Control Center",
                     frame: CGRect(x: -3930, y: 0, width: 36, height: 33),
                     isOnScreen: false),
        ObservedItem(windowNumber: 8392, ownerPID: 1, bundleID: nil,
                     ownerName: "Control Center",
                     frame: CGRect(x: -3894, y: 0, width: 5_016, height: 33),
                     isOnScreen: true),
    ]

    #expect(RevealCoordinator.uniqueSentinelItem(bundleID: acme.bundleID,
                                                  identities: [acme, chatGPT],
                                                  items: items)?.windowNumber == 155)
}

@Test @MainActor func sentinelOwnerRefusesAnAmbiguousHiddenWindow() {
    let acme = BarItemOwners.Owner(name: "ACME", bundleID: "com.amazon.ACME",
                                   pid: 4050, axLeftEdge: -1)
    let items = [
        ObservedItem(windowNumber: 155, ownerPID: 1, bundleID: nil,
                     ownerName: "Control Center",
                     frame: CGRect(x: -3930, y: 0, width: 36, height: 33),
                     isOnScreen: false),
        ObservedItem(windowNumber: 156, ownerPID: 1, bundleID: nil,
                     ownerName: "Control Center",
                     frame: CGRect(x: -3890, y: 0, width: 36, height: 33),
                     isOnScreen: false),
    ]

    #expect(RevealCoordinator.uniqueSentinelItem(bundleID: acme.bundleID,
                                                  identities: [acme],
                                                  items: items) == nil)
}

@Test func hiddenSentinelPositionIsNeverPressed() {
    #expect(!PressActionProbe.positionIsVisible(-1))
    #expect(!PressActionProbe.positionIsVisible(0))
    #expect(PressActionProbe.positionIsVisible(1))
    #expect(PressActionProbe.positionIsVisible(1_200))
}

@Test func revealPresentationClampsProgressAndRoundsAccessibilitySecondsUp() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let presentation = RevealPresentation(bundleID: "com.example.app",
                                          startedAt: start,
                                          deadline: start.addingTimeInterval(15))

    #expect(presentation.progress(at: start.addingTimeInterval(-1)) == 1)
    #expect(presentation.progress(at: start.addingTimeInterval(7.5)) == 0.5)
    #expect(presentation.progress(at: start.addingTimeInterval(16)) == 0)
    #expect(presentation.secondsRemaining(at: start.addingTimeInterval(2.1)) == 13)
    #expect(presentation.matches("com.example.app"))
    #expect(!presentation.matches("com.example.other"))
}

// MARK: - Config: revealDuration
//
// The temporary-reveal duration follows the exact optional-field-plus-clamped-accessor
// pattern as `autoTuckDelaySeconds`/`autoTuckDelay`: a config saved before this field
// existed must still decode, and the clamp must never let a hand-edited zero or
// negative value tuck an item before its menu could ever be reached.

@Test func revealDurationDefaultsToFifteenSecondsWhenUnset() {
    #expect(Config.default.revealDurationSeconds == nil)
    #expect(Config.default.revealDuration == 15)
}

@Test func revealDurationHonoursAnExplicitValue() {
    var config = Config.default
    config.revealDurationSeconds = 30
    #expect(config.revealDuration == 30)
}

@Test func revealDurationClampsToAOneSecondFloor() {
    // Zero or negative would tuck the item before the menu it was revealed for could
    // ever be reached, exactly the failure `autoTuckDelay`'s own clamp exists to
    // prevent.
    var zero = Config.default
    zero.revealDurationSeconds = 0
    #expect(zero.revealDuration == 1)

    var negative = Config.default
    negative.revealDurationSeconds = -5
    #expect(negative.revealDuration == 1)
}

@Test func revealDurationSecondsRoundTripsThroughSaveAndLoad() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-reveal-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    var written = Config.default
    written.revealDurationSeconds = 22
    try written.save(to: url)

    let loaded = Config.load(from: url)
    #expect(loaded.revealDurationSeconds == 22)
    #expect(loaded.revealDuration == 22)
    #expect(loaded == written)
}

@Test func aConfigWrittenBeforeRevealDurationExistedStillDecodesWithTheDocumentedDefault() throws {
    // Hand-crafted, not encoded from a Config, for the same reason every other
    // missing-field test in this suite is hand-crafted: encoding always writes every
    // key, so it can never exercise the omitted-key path a config written by an older
    // build actually produces.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-reveal-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    let olderBuild = """
    {
        "revealOnHover": true
    }
    """
    try Data(olderBuild.utf8).write(to: url)

    let loaded = Config.load(from: url)
    #expect(loaded.revealDurationSeconds == nil)
    #expect(loaded.revealDuration == 15)
}

// MARK: - RevealCoordinator.NextStep: which item gets put back before a new reveal
//
// The actual move through ItemMover needs a live bar and is not unit-testable, exactly
// like ItemMover and BarArranger's own move calls. What IS pure, and what this guards,
// is the decision `reveal` makes about the item ALREADY revealed before it touches
// anything: restart its timer if it is the same app, tuck it back first if it is a
// different one, or do nothing if none is revealed yet. `ItemMover` only ever moves one
// item at a time, so getting this decision wrong is exactly how a first revealed item
// would leak onto the bar permanently when a second one is opened.

@Test func nextStepRevealsFreshWhenNothingIsCurrentlyRevealed() {
    let step = RevealCoordinator.NextStep.decide(currentlyRevealed: nil,
                                                  requesting: "com.example.first")
    #expect(step == .revealFresh)
}

@Test func nextStepRestartsTheTimerWhenTheSameAppIsClickedAgain() {
    let step = RevealCoordinator.NextStep.decide(currentlyRevealed: "com.example.first",
                                                  requesting: "com.example.first")
    #expect(step == .restartTimer)
}

@Test func nextStepTucksThePreviousAppBeforeRevealingADifferentOne() {
    let step = RevealCoordinator.NextStep.decide(currentlyRevealed: "com.example.first",
                                                  requesting: "com.example.second")
    #expect(step == .tuckThenRevealFresh(previous: "com.example.first"))
}

// MARK: - RevealCoordinator: initial state
//
// Everything past this point needs a live bar (ItemMover.barItems(), a real seam
// window) and is exactly the part the assignment says not to unit test. What is left
// that is both pure and observable without one is the coordinator's starting state.

// The shared instance, because the initialiser is private: the coordinator owns a re-tuck timer
// that must outlive a view rebuild, and SwiftUI was measured destroying a `@StateObject` one
// mid-launch. Asserting on `shared` before anything has revealed is still a real assertion about
// its starting state, and it additionally pins the invariant that merely reaching for the
// coordinator does not reveal anything.
@Test @MainActor func aFreshRevealCoordinatorIsRevealingNothing() {
    #expect(RevealCoordinator.shared.revealedBundleID == nil)
    #expect(RevealCoordinator.shared.isRevealing == false)
}
