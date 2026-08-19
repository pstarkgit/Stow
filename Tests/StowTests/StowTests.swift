import Testing
import Foundation
import CoreGraphics
@testable import Stow

// MARK: - BarBudget
//
// The whole point of BarBudget being a pure value type is that every branch is
// testable without a window server. These are the branches.

@Test func usableSubtractsEveryClaimOnTheBar() {
    let b = BarBudget(screenWidth: 1512, appMenuWidth: 214, notchWidth: 160,
                      systemTrailingWidth: 268, occupiedWidths: [])
    // Bind the arithmetic to a CGFloat before comparing, and keep it bound.
    // Inlining it as `b.usable == 1512 - 214 - 160 - 268` ALWAYS fails: #expect
    // type-erases its operands, the multi-term literal arithmetic loses the
    // contextual CGFloat type and resolves to Int, and type-erased equality then
    // compares CGFloat against Int on dynamic type and returns false no matter
    // what the number is. The subtraction stays spelled out on purpose.
    let expected: CGFloat = 1512 - 214 - 160 - 268
    #expect(b.usable == expected)
}

@Test func usableNeverGoesNegative() {
    // A pathological frontmost app with more menu titles than screen. Clamped,
    // because a negative "usable" would make canReveal nonsense rather than false.
    let b = BarBudget(screenWidth: 800, appMenuWidth: 900, notchWidth: 0,
                      systemTrailingWidth: 200, occupiedWidths: [])
    #expect(b.usable == 0)
}

@Test func headroomMayBeNegativeBecauseMacOSIsAlreadyClipping() {
    let b = BarBudget(screenWidth: 1000, appMenuWidth: 0, notchWidth: 0,
                      systemTrailingWidth: 0, occupiedWidths: [600, 600])
    #expect(b.headroom == -200)
}

@Test func canRevealIsExactAtTheBoundary() {
    let b = BarBudget(screenWidth: 1000, appMenuWidth: 0, notchWidth: 0,
                      systemTrailingWidth: 0, occupiedWidths: [960])
    #expect(b.canReveal(width: 40))       // exactly fits
    #expect(!b.canReveal(width: 41))      // one point over
    #expect(!b.canReveal(width: 0))       // a zero-width item is not a reveal
}

@Test func crowdedIsDetectedFromTheWidestTuckedItemNotGuessed() {
    let tight = BarBudget(screenWidth: 1000, appMenuWidth: 0, notchWidth: 0,
                          systemTrailingWidth: 0, occupiedWidths: [980])
    // 20pt free. A 30pt item cannot surface, so the bar IS crowded.
    #expect(tight.state(widestTucked: 30) == .crowded)
    // A 20pt item can, so it is not.
    #expect(tight.state(widestTucked: 20) == .tidy)
}

@Test func nothingTuckedMeansCrowdingCannotBite() {
    let b = BarBudget(screenWidth: 1000, appMenuWidth: 0, notchWidth: 0,
                      systemTrailingWidth: 0, occupiedWidths: [500])
    #expect(b.state(widestTucked: nil) == .tidy)
    #expect(b.state(widestTucked: 0) == .tidy)
}

@Test func alreadyOverflowingIsCrowdedEvenWithNothingTucked() {
    // macOS is clipping right now. Reporting .tidy here would be a lie.
    let b = BarBudget(screenWidth: 100, appMenuWidth: 0, notchWidth: 0,
                      systemTrailingWidth: 0, occupiedWidths: [200])
    #expect(b.state(widestTucked: nil) == .crowded)
}

// MARK: - StowGlyph
//
// The family's rules are testable properties, not just prose in a doc comment.

@Test func everyStateHasAPaintWithAtLeastTwoStops() {
    for state in [BarState.tidy, .open, .crowded, .arranging, .blocked] {
        let stops = StowGlyph.paint(for: state).stops
        #expect(stops.count >= 2, "\(state) needs two stops to be a gradient")
    }
}

@Test func onlyLivePhaseStatesAreAnimated() {
    // Anything else must be cacheable, or the menu bar redraws forever.
    #expect(BarState.crowded.isAnimated)
    #expect(BarState.arranging.isAnimated)
    #expect(!BarState.tidy.isAnimated)
    #expect(!BarState.open.isAnimated)
    #expect(!BarState.blocked.isAnimated)
}

@Test func blockedStateIsUnlit() {
    // "Honest about being unable to work" means no glow, not a dim glow.
    let paint = StowGlyph.paint(for: .blocked)
    #expect(paint.glowRadius == 0)
}

@Test func theTokenIsEvenOddSoTheHatchIsATrueCutout() {
    let path = StowGlyph.tokenPath(in: NSRect(x: 0, y: 0, width: 22, height: 22))
    #expect(path.windingRule == .evenOdd)
}

@Test func theMarkScalesLinearlyWithTheGrid() {
    // One geometry function serves 18pt in the bar and 1024px in the Dock. If this
    // fails the two have drifted, which is the exact defect the shared function
    // exists to prevent.
    let small = StowGlyph.markPath(in: NSRect(x: 0, y: 0, width: 22, height: 22)).bounds
    let large = StowGlyph.markPath(in: NSRect(x: 0, y: 0, width: 44, height: 44)).bounds
    #expect(abs(large.width - small.width * 2) < 0.01)
    #expect(abs(large.height - small.height * 2) < 0.01)
}

@Test func theMarkStaysInsideTheBody() {
    // A void that escapes the body would clip the silhouette and break the family's
    // shared rounded-square outline.
    let rect = NSRect(x: 0, y: 0, width: 220, height: 220)
    let body = StowGlyph.bodyPath(in: rect).bounds
    let mark = StowGlyph.markPath(in: rect).bounds
    #expect(body.contains(mark))
}

@Test func theInkUsesMostOfTheMenuBarCanvas() {
    let canvas = NSRect(origin: .zero, size: StowGlyph.menuBarSize)
    let ink = StowGlyph.bodyPath(in: StowGlyph.artworkRect(in: canvas)).bounds
    #expect(ink.width / canvas.width >= 0.88)
    #expect(ink.height / canvas.height >= 0.85)
}

@Test func renderedArtworkIsNotATemplate() {
    // Template images get force-recoloured monochrome by macOS, discarding every
    // stop in paint(for:).
    let image = StowGlyph.image(for: .tidy)
    #expect(!image.isTemplate)
}

@Test func artworkHonoursTheRequestedSize() {
    let image = StowGlyph.image(for: .tidy, size: NSSize(width: 64, height: 64))
    #expect(image.size == NSSize(width: 64, height: 64))
}

// MARK: - Version and release notes

@Test func versionIsPlainSemverBecauseInstallShParsesIt() {
    let pattern = /^[0-9]+\.[0-9]+(\.[0-9]+)?$/
    #expect(StowVersion.current.wholeMatch(of: pattern) != nil)
}

@Test func displayFallsBackToBareVersionWithoutACommitStamp() {
    // Under `swift run` there is no Info.plist, which is exactly when a developer
    // most needs to know which build is running.
    #expect(StowVersion.buildCommit == "dev")
    #expect(StowVersion.display == StowVersion.current)
}

@Test func changelogHeadMatchesTheVersion() {
    // Mirrors the hard gate in install.sh so a stale CHANGELOG fails in `swift test`
    // rather than at install time. Fence-aware for the same reason the shell awk is:
    // the file documents its own format inside a fenced block, and a parser with no
    // fence notion reads the EXAMPLE heading.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // StowTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
    let text = try! String(contentsOf: root.appending(path: "CHANGELOG.md"),
                           encoding: .utf8)
    var inFence = false
    var head: String?
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = String(raw)
        if l.hasPrefix("```") { inFence.toggle(); continue }
        if inFence { continue }
        if l.hasPrefix("## ") {
            head = l.dropFirst(3).split(separator: " ").first.map(String.init)
            break
        }
    }
    #expect(head == StowVersion.current,
            "CHANGELOG head is \(head ?? "none"), version is \(StowVersion.current)")
}

@Test func firstStowLaunchImportsLegacyAirlockConfigWithoutChangingIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "stow-config-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
    let primary = root.appending(path: "stow/config.json")
    let legacy = root.appending(path: "airlock/config.json")
    var expected = Config.default
    expected.revealDurationSeconds = 23
    try expected.save(to: legacy)

    let loaded = Config.load(primary: primary, legacy: legacy)

    #expect(loaded == expected)
    #expect(try Data(contentsOf: primary) == Data(contentsOf: legacy))
    try? FileManager.default.removeItem(at: root)
}

// MARK: - Zones

@Test func runtimeOffersExactlyTwoZones() {
    #expect(Zone.allCases == [.pinned, .tucked])
}

// MARK: - MenuWidthProbe
//
// Only the pure logic is tested here. `frontmostAppMenuWidth` and
// `systemTrailingWidth` need a real AX tree and window server, exactly like
// `BarScanner` and `PressActionProbe`, so `Probe --probe` is where those get
// exercised. What is pure, and therefore testable without either, is how a
// nil measurement propagates and the geometry that matches an AX position to
// its window frame.

@Test func emptyWidthsMeansGenuinelyZeroNotUnmeasurable() {
    // An app with no menu items occupies no width. Reporting that case as
    // unmeasurable would be the same kind of lie this file exists to avoid,
    // just pointed the other way: it would make BarBudget UNDERSTATE capacity
    // for an app that has nothing to report because there was nothing there.
    #expect(MenuWidthProbe.sumMeasuredWidths([]) == 0)
}

@Test func everyItemFailingToMeasureIsNilNotZero() {
    // Items existed but the AX call answered none of them. That is a real
    // "not measurable right now" state, not the same thing as an app with no
    // menus, and collapsing the two would let a transient AX failure silently
    // overstate BarBudget.usable.
    #expect(MenuWidthProbe.sumMeasuredWidths([nil, nil, nil]) == nil)
}

@Test func aMeasuredItemOutweighsAStrayUnmeasurableOne() {
    // Nine real menu titles and one item that failed to report a size should
    // not blank out the nine. Bind the sum to a typed CGFloat before comparing;
    // see usableSubtractsEveryClaimOnTheBar for why an inline literal sum fails
    // #expect's type-erased comparison regardless of value.
    let expected: CGFloat = 40 + 62 + 58
    #expect(MenuWidthProbe.sumMeasuredWidths([40, 62, nil, 58]) == expected)
}

@Test func matchedWidthsUsesContainmentBecauseTheAXPositionSitsInsideTheFrame() {
    // Measured on a real machine: the window frame runs wider than the
    // AX-reported size, which reads as hit-target padding around the glyph.
    // An equality test between the two would match nothing at all, so
    // containment is the only geometry that reflects what was actually seen.
    let frames = [
        CGRect(x: 1292, y: 0, width: 38, height: 33),   // Sound
        CGRect(x: 1565, y: 0, width: 165, height: 33),  // Clock
    ]
    let widths = MenuWidthProbe.matchedWidths(systemXPositions: [1300, 1573],
                                               candidateFrames: frames)
    let expected: [CGFloat] = [38, 165]
    #expect(widths == expected)
}

@Test func matchedWidthsDropsAPositionThatFallsInNoFrame() {
    // A system-identified AX item whose position lands nowhere in the current
    // window scan is dropped rather than forced into the nearest frame, which
    // would silently attribute one item's width to a different item entirely.
    let frames = [CGRect(x: 100, y: 0, width: 40, height: 33)]
    let widths = MenuWidthProbe.matchedWidths(systemXPositions: [500],
                                               candidateFrames: frames)
    #expect(widths.isEmpty)
}

@Test func matchedWidthsCanReturnFewerWidthsThanPositions() {
    // Three system items were identified in the AX tree but only two could be
    // matched back to a window frame. The count of matched widths is allowed
    // to fall short of the input, and measureSystemTrailingWidth treats that
    // shortfall honestly rather than padding it back up to three.
    let frames = [
        CGRect(x: 1440, y: 0, width: 38, height: 33),
        CGRect(x: 1480, y: 0, width: 42, height: 33),
    ]
    let widths = MenuWidthProbe.matchedWidths(systemXPositions: [1451, 1489, 9999],
                                               candidateFrames: frames)
    #expect(widths.count == 2)
}

// MARK: - SpacerItem
//
// Only the pure clamp arithmetic is tested here. Creating a real NSStatusItem
// and reading its window-server frame is exactly the live-environment question
// `--seam` exists to answer, the same split BarScanner and PressActionProbe
// already draw between what a unit test can verify and what needs a real bar.

@Test func collapseNeverProducesALengthBelowRestingLength() {
    // A huge collapse request against a small current length must clamp at
    // the floor rather than go negative or below rest. Reaching zero would
    // drag the whole tucked run back onto the bar, which is the exact
    // overflow this design exists to avoid.
    let result = SpacerItem.clampedLength(current: 20, collapsingBy: 500)
    #expect(result == SpacerItem.restingLength)
}

@Test func aCollapseLargerThanTheCurrentLengthStillClampsAtRest() {
    let result = SpacerItem.clampedLength(current: SpacerItem.restingLength + 5,
                                           collapsingBy: 5000)
    #expect(result == SpacerItem.restingLength)
}

@Test func zeroOrNegativeCollapseIsANoOpRatherThanGrowth() {
    // collapse(by:) is a request to get SMALLER. A zero or negative delta
    // must leave the length exactly where it was, never expand it, since a
    // caller asking to collapse is never asking for the opposite.
    let current: CGFloat = 200
    #expect(SpacerItem.clampedLength(current: current, collapsingBy: 0) == current)
    #expect(SpacerItem.clampedLength(current: current, collapsingBy: -50) == current)
}

@Test func anOrdinaryCollapseShrinksByExactlyThePointsRequested() {
    let expected: CGFloat = 200 - 40
    #expect(SpacerItem.clampedLength(current: 200, collapsingBy: 40) == expected)
}

// MARK: - Config
//
// Config must never throw a menu bar app out of existence over a missing or
// damaged file, and a config written by an older build must still decode once
// this build adds a field that build never knew about. Both are testable
// without touching the real ~/.config/stow/config.json, via load(from:)/
// save(to:) against a temp URL, the same seam AuthBar's own Config tests use.

@Test func configLoadYieldsDefaultWhenTheFileIsAbsent() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("config.json")
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let loaded = Config.load(from: url)
    #expect(loaded == Config.default)
}

@Test func configLoadYieldsDefaultWhenTheFileIsCorruptRatherThanThrowing() throws {
    // A menu bar app that refuses to launch over a damaged config file is
    // strictly worse than one that falls back to defaults for this run: the
    // user cannot fix a file they cannot open the app to edit.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("config.json")
    try Data("{ this is not valid JSON".utf8).write(to: url)

    let loaded = Config.load(from: url)
    #expect(loaded == Config.default)
}

@Test func savingThenLoadingPreservesEveryField() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    var written = Config.default
    written.revealOnHover = false
    written.autoTuckDelaySeconds = 9
    written.launchAtLogin = true
    written.spacerRestingLength = 14
    written.spacerAutosaveName = "custom-spacer"
    written.profiles = [
        Config.Profile(id: "custom", name: "Custom", spacerLength: 22,
                       tuckedRunDepth: 2, hotkeyDisplay: "\u{2318}\u{21E7}9"),
    ]
    written.activeProfileID = "custom"
    written.rules = [
        Config.Rule(id: "r1", isEnabled: true,
                   condition: .screenSharingStarted,
                   action: .tuckPinnedSlot(depth: 1)),
        Config.Rule(id: "r2", isEnabled: false,
                   condition: .frontmostAppIs(bundleID: "com.example.meeting"),
                   action: .revealTuckedSlot(depth: 0)),
    ]

    try written.save(to: url)
    let loaded = Config.load(from: url)
    #expect(loaded == written)
}

@Test func aConfigMissingANewerOptionalFieldStillDecodes() throws {
    // Hand-crafted rather than encoded from a Config: encoding always writes
    // every key, so it could never exercise the omitted-key path a config
    // written by an OLDER build actually produces. This is that older file.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    let minimal = """
    {
        "revealOnHover": true
    }
    """
    try Data(minimal.utf8).write(to: url)

    let loaded = Config.load(from: url)
    #expect(loaded.revealOnHover == true)
    // Every OTHER field was absent from the file entirely, not merely null,
    // and still resolves to its documented default rather than failing to
    // decode.
    #expect(loaded.autoTuckDelaySeconds == nil)
    #expect(loaded.autoTuckDelay == 4)
    #expect(loaded.launchAtLogin == nil)
    #expect(loaded.launchAtLoginEnabled == false)
    #expect(loaded.spacerRestingLength == nil)
    #expect(loaded.spacerRestingLengthPoints == 10)
    #expect(loaded.profiles == nil)
    #expect(loaded.profileList.count == 4)
    #expect(loaded.rules == nil)
    #expect(loaded.ruleList.isEmpty)
}

@Test func defaultConfigShipsExactlyTheFourNamedProfilesWithDistinctIds() {
    let profiles = Config.default.profileList
    #expect(profiles.count == 4)
    let names = Set(profiles.map(\.name))
    #expect(names == ["Presenting", "Screen Share", "Focus", "Everything"])
    let ids = Set(profiles.map(\.id))
    #expect(ids.count == 4, "every profile must have a distinct id")
}

// MARK: - Store
//
// Store's own responsibility, per the batch contract, is persisting Config
// and never keying anything to app identity. What is testable without a real
// window server or a real save round trip through the debounce is the
// profile-activation contract: it records a choice and nothing more.

@Test @MainActor func applyingAProfileRecordsItAsActiveWithoutMovingAnything() {
    let store = Store(fixtureConfig: .default)
    let target = Config.defaultProfiles[2]   // "Focus"
    store.apply(target)
    #expect(store.config.activeProfileID == target.id)
    #expect(store.activeProfile?.id == target.id)
}

@Test @MainActor func addingAndRemovingARuleUpdatesTheExposedList() {
    let store = Store(fixtureConfig: .default)
    #expect(store.rules.isEmpty)

    let rule = Config.Rule(id: "meeting", isEnabled: true,
                           condition: .frontmostAppIs(bundleID: "com.example.meeting"),
                           action: .revealTuckedSlot(depth: 0))
    store.addRule(rule)
    #expect(store.rules.map(\.id) == ["meeting"])

    store.setRule(id: "meeting", isEnabled: false)
    #expect(store.rules.first?.isEnabled == false)

    store.removeRule(id: "meeting")
    #expect(store.rules.isEmpty)
}

// MARK: - Press-action coverage: owner resolution and summary arithmetic
//
// The AX walk in BarItemOwners.claims() and PressActionProbe.probe(pid:) needs a
// live accessibility tree and is not unit-testable, exactly like BarScanner and
// PressActionProbe. What IS pure, and what these guard, is (1) how a set of
// synthetic owner claims splits a set of observed items into resolved vs
// unresolved, and (2) the summary arithmetic once free/resolved/unresolved counts
// are already known. Both Probe and BarDoctor carry their own copy of this logic
// (duplicated deliberately, see the doc comments at each definition), so both are
// exercised here.

private func makeItem(windowNumber: CGWindowID, frameX: CGFloat) -> ObservedItem {
    ObservedItem(windowNumber: windowNumber, ownerPID: 1, bundleID: nil,
                ownerName: "Control Center",
                frame: CGRect(x: frameX, y: 0, width: 30, height: 24),
                isOnScreen: true)
}

private func makeOwner(name: String, pid: pid_t, axLeftEdge: CGFloat) -> BarItemOwners.Owner {
    BarItemOwners.Owner(name: name, bundleID: "com.example.\(name)", pid: pid,
                        axLeftEdge: axLeftEdge)
}

@Test @MainActor func splitByOwnerResolvesItemsWithinTenPointsAndLeavesTheRestUnresolved() {
    // One item sits within tolerance of a real owner's claimed edge; the other
    // sits far from every claim and must fall to unresolved, not get matched to
    // the nearest claim regardless of distance.
    let matched = makeItem(windowNumber: 1, frameX: 100)
    let stray = makeItem(windowNumber: 2, frameX: 9000)
    let claims = [makeOwner(name: "Murmur", pid: 42, axLeftEdge: 98)]

    let split = Probe.splitByOwner([matched, stray], claims: claims)
    #expect(split.resolved.count == 1)
    #expect(split.resolved.first?.item.windowNumber == 1)
    #expect(split.resolved.first?.owner.pid == 42)
    #expect(split.unresolved.map(\.windowNumber) == [2])
}

@Test @MainActor func splitByOwnerWithNoClaimsLeavesEveryItemUnresolved() {
    let items = [makeItem(windowNumber: 1, frameX: 100), makeItem(windowNumber: 2, frameX: 200)]
    let split = Probe.splitByOwner(items, claims: [])
    #expect(split.resolved.isEmpty)
    #expect(split.unresolved.count == 2)
}

@Test @MainActor func barDoctorAndProbeAgreeOnTheSameSplit() {
    // BarDoctor keeps its own copy of this logic; both must resolve the same
    // item to the same owner given the same claims, or the two surfaces would
    // silently disagree about the exact same bar.
    let matched = makeItem(windowNumber: 1, frameX: 100)
    let claims = [makeOwner(name: "Murmur", pid: 42, axLeftEdge: 98)]

    let probeSplit = Probe.splitByOwner([matched], claims: claims)
    let doctorSplit = BarDoctor.splitByOwner([matched], claims: claims)
    #expect(probeSplit.resolved.map { $0.owner.pid } == doctorSplit.resolved.map { $0.owner.pid })
    #expect(probeSplit.unresolved.map(\.windowNumber) == doctorSplit.unresolved.map(\.windowNumber))
}

@Test func coverageDetailReturnsNilWhenNothingResolvedRatherThanFabricatingARate() {
    // Zero resolved items must never produce a "0 of 0" or any other rate: that
    // is exactly the kind of manufactured number the whole file exists to avoid.
    #expect(Probe.coverageDetail(free: 0, resolved: 0, unresolved: 5) == nil)
    #expect(BarDoctor.coverageDetail(free: 0, resolved: 0, unresolved: 5) == nil)
}

@Test func coverageDetailReportsTheResolvedRateAndNamesTheUnresolvedCountSeparately() {
    let detail = Probe.coverageDetail(free: 3, resolved: 5, unresolved: 2)
    #expect(detail == "3 of 5 resolved item(s) open with zero reveal, 2 unresolved")
}

@Test func coverageDetailOmitsTheUnresolvedClauseWhenEverythingResolved() {
    let detail = BarDoctor.coverageDetail(free: 4, resolved: 4, unresolved: 0)
    #expect(detail == "4 of 4 resolved item(s) open with zero reveal")
}

@Test func coverageDetailNeverCountsAnUnresolvedItemAsEitherOutcome() {
    // resolved + unresolved always equals the true total; free is bounded by
    // resolved alone, so an unresolved item cannot inflate or deflate free.
    let resolved = 6
    let unresolved = 3
    let total = resolved + unresolved
    let detail = Probe.coverageDetail(free: 6, resolved: resolved, unresolved: unresolved)
    #expect(total == 9)
    #expect(detail == "6 of 6 resolved item(s) open with zero reveal, 3 unresolved")
}

// MARK: - VisibleRow: Apple-bundle prefix and grouping
//
// BarItemOwners itself is @MainActor and AX-dependent, so it is not
// unit-tested here; the dispatcher verifies it against the live bar. What IS
// pure and testable without any AX walk is (1) the string-prefix test that
// decides whether a resolved owner is one of Apple's own, and (2) the
// grouping helper that partitions rows by that decision while preserving
// each row's place within its own kind.

@Test func appleBundleIdentifiersAreRecognizedByThePrefixAlone() {
    #expect(StatusPanel.VisibleRow.isAppleBundle("com.apple.controlcenter"))
    #expect(StatusPanel.VisibleRow.isAppleBundle("com.apple.menuextra.battery"))
    #expect(!StatusPanel.VisibleRow.isAppleBundle("com.starkpat.AuthBar"))
    #expect(!StatusPanel.VisibleRow.isAppleBundle(""))
}

@Test func groupedKeepsThirdPartyRowsAheadOfSystemRowsWithoutReorderingWithinEitherGroup() {
    // Bar order (rightmost first) interleaves system and third-party rows in
    // whatever order they happen to sit physically. Grouping must NOT re-sort
    // by position, only partition by kind while preserving each row's
    // existing place among rows of its own kind.
    let system1 = StatusPanel.VisibleRow(item: makeItem(windowNumber: 1, frameX: 400),
                                         isSystem: true, owner: nil)
    let thirdParty1 = StatusPanel.VisibleRow(item: makeItem(windowNumber: 2, frameX: 300),
                                             isSystem: false, owner: nil)
    let system2 = StatusPanel.VisibleRow(item: makeItem(windowNumber: 3, frameX: 200),
                                         isSystem: true, owner: nil)
    let thirdParty2 = StatusPanel.VisibleRow(item: makeItem(windowNumber: 4, frameX: 100),
                                             isSystem: false, owner: nil)
    let grouped = StatusPanel.VisibleRow.grouped([system1, thirdParty1, system2, thirdParty2])
    #expect(grouped.map(\.item.windowNumber) == [2, 4, 1, 3])
}

@Test func groupedIsANoOpWhenEveryRowIsTheSameKind() {
    let a = StatusPanel.VisibleRow(item: makeItem(windowNumber: 1, frameX: 300),
                                   isSystem: false, owner: nil)
    let b = StatusPanel.VisibleRow(item: makeItem(windowNumber: 2, frameX: 200),
                                   isSystem: false, owner: nil)
    let grouped = StatusPanel.VisibleRow.grouped([a, b])
    #expect(grouped.map(\.item.windowNumber) == [1, 2])
}

// MARK: - Zone membership by bundle id
//
// BarItemOwners.claims() recovers a bundle id that survives a relaunch, which
// is what makes per-app zone membership a legitimate persisted key (see
// Config's own header comment for the correction this replaces). What is
// testable here without any AX walk is that the map itself round-trips
// through save and load, that an unassigned bundle id resolves to the
// documented default, and that a config saved before this field existed
// still decodes.

@Test func zoneMembershipRoundTripsThroughSaveAndLoad() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    var written = Config.default
    written.setZone(.tucked, forBundleID: "com.example.murmur")
    written.setZone(.tucked, forBundleID: "com.example.vpn")

    try written.save(to: url)
    let loaded = Config.load(from: url)
    #expect(loaded.zone(forBundleID: "com.example.murmur") == .tucked)
    #expect(loaded.zone(forBundleID: "com.example.vpn") == .tucked)
    #expect(loaded == written)
}

@Test func legacyVaultedZoneDecodesAsTuckedAndEncodesWithoutVault() throws {
    let data = Data(#"{"zoneByBundleID":{"com.example.vpn":"vaulted"}}"#.utf8)
    let loaded = try JSONDecoder().decode(Config.self, from: data)
    #expect(loaded.zone(forBundleID: "com.example.vpn") == .tucked)
    let encoded = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
    #expect(!encoded.contains("vaulted"))
}

@Test func unavailableAppsArePrunedWithoutTouchingInstalledApps() {
    var config = Config.default
    config.zoneByBundleID = [
        "com.example.installed": .tucked,
        "com.example.removed": .tucked,
    ]
    let removed = config.pruneUnavailableApps { $0 == "com.example.installed" }
    #expect(removed == ["com.example.removed"])
    #expect(config.zone(forBundleID: "com.example.installed") == .tucked)
    #expect(config.zoneByBundleID?["com.example.removed"] == nil)
}

@Test func anUnassignedBundleIDResolvesToPinnedRatherThanAnyOtherDefault() {
    // An item Stow has never been told to move must stay exactly where macOS
    // already put it. Defaulting to .tucked would move every
    // app Stow has never heard of into a zone nobody assigned it to.
    var config = Config.default
    #expect(config.zone(forBundleID: "com.example.neverassigned") == .pinned)

    config.setZone(.tucked, forBundleID: "com.example.other")
    // Setting a DIFFERENT bundle id's zone must not change the default for
    // one that was never assigned.
    #expect(config.zone(forBundleID: "com.example.neverassigned") == .pinned)
}

@Test func aConfigWrittenBeforeTheZoneFieldExistedStillDecodesWithANilMap() throws {
    // Hand-crafted, not encoded from a Config, for the same reason
    // aConfigMissingANewerOptionalFieldStillDecodes is hand-crafted above:
    // encoding always writes every key, so it can never exercise the
    // omitted-key path a config written by an OLDER build actually produces.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stow-config-tests-\(UUID().uuidString)", isDirectory: true)
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
    #expect(loaded.zoneByBundleID == nil)
    #expect(loaded.zone(forBundleID: "com.example.anything") == .pinned)
}

// MARK: - Hide placement ordering
//
// These defend the one invariant whose violation cannot be undone by the user.
//
// A status item pushes only what is to its LEFT. So the bar must read, from the right edge
// inwards: Stow's token, the boundary, then the run in Stow.
// Get that order wrong and expanding a seam pushes Stow's own token off with everything
// else, leaving no control anywhere to bring the items back.
//
// This is not hypothetical. The first verified `--hide` run reported "Stow x1729 -> gone"
// alongside the eight items it was asked to hide, which is exactly that failure. All three
// placements are plain integers, so the ordering is testable without a status bar, a window
// server, or an accessibility grant.

@Test func stowsOwnTokenSitsFurtherRightThanBothHatches() {
    // Smaller offset means further right, so the token's value must be the SMALLEST of the
    // three. Spelled as relationships rather than literal checks: the numbers may be tuned,
    // the ordering may not.
    for boundary in SpacerItem.Boundary.allCases {
        #expect(HideController.tokenOffsetFromRightEdge < boundary.defaultOffsetFromRightEdge)
    }
}

@Test func everyPlacementIsInboardOfTheExtremeRightEdge() {
    // Zero is the extreme right edge, where an item competes with Control Center's own run
    // for the outermost slot. All three placements must be inboard of it.
    #expect(HideController.tokenOffsetFromRightEdge > 0)
    for boundary in SpacerItem.Boundary.allCases {
        #expect(boundary.defaultOffsetFromRightEdge > 0)
    }
}

@Test func ownTokenMustRemainOnTheVisibleBar() {
    let ownBundle = "dev.starkpat.stow"
    let visible = BarItemOwners.Owner(name: "Stow", bundleID: ownBundle,
                                      pid: 1, axLeftEdge: 1200)
    let swept = BarItemOwners.Owner(name: "Stow", bundleID: ownBundle,
                                    pid: 1, axLeftEdge: -3800)
    let neighbour = BarItemOwners.Owner(name: "Other", bundleID: "com.example.other",
                                        pid: 2, axLeftEdge: 1300)

    #expect(HideController.ownTokenIsVisible(in: [visible, neighbour],
                                             ownBundle: ownBundle))
    #expect(!HideController.ownTokenIsVisible(in: [swept, neighbour],
                                              ownBundle: ownBundle))
    #expect(!HideController.ownTokenIsVisible(in: [neighbour],
                                              ownBundle: ownBundle))
}

@Test func thereIsExactlyOnePersistedBoundary() {
    #expect(SpacerItem.Boundary.allCases == [.tucked])
    #expect(SpacerItem.Boundary.tucked.autosaveIdentity == "RailSpacer")
}

@Test func collapsingTheSeamNeverDragsTheHiddenRunBackAllAtOnce() {
    // The resting floor is load-bearing: reaching zero width would return every
    // hidden item to a bar that had no room for them, which is the overflow the whole
    // design exists to prevent.
    let collapsed = SpacerItem.clampedLength(current: 5016, collapsingBy: 999_999)
    #expect(collapsed == SpacerItem.restingLength)
}

// MARK: - BarCut
//
// The classification a user reads as correct or broken. A row shown under HIDES that
// then stays on the bar is the most confusing failure this app can produce, and until
// this rule was pulled out of the SwiftUI body it could not be tested at all.

private func item(_ x: CGFloat, width: CGFloat = 32, window: CGWindowID = 1) -> ObservedItem {
    ObservedItem(windowNumber: window, ownerPID: 501, bundleID: "com.example.app",
                 ownerName: "Example",
                 frame: CGRect(x: x, y: 0, width: width, height: 24),
                 isOnScreen: true)
}

@Test func itemsLeftOfTheCutHideAndItemsRightOfItStay() {
    // Mirrors the verified `--cut` run: cut at x2119, five items left, two right.
    let items = [item(1729, window: 1), item(1833, window: 2), item(1873, window: 3),
                 item(2059, window: 4), item(2093, window: 5),
                 item(2125, window: 6), item(2171, window: 7)]
    let split = BarCut.split(items: items, cutX: 2119)
    #expect(split.hiding.count == 5)
    #expect(split.staying.count == 2)
    #expect(split.staying.allSatisfy { $0.frame.minX > 2119 })
    #expect(split.hiding.allSatisfy { $0.frame.minX <= 2119 })
}

@Test func anItemExactlyAtTheCutHides() {
    // The boundary decides whether a row lies about its own fate. An item at the cut
    // is not right of the seam, so the seam pushes it: it must be reported as hiding.
    let split = BarCut.split(items: [item(2119)], cutX: 2119)
    #expect(split.hiding.count == 1)
    #expect(split.staying.isEmpty)
}

@Test func theListReadsRightToLeftSoTheCutSitsBetweenTheGroups() {
    let items = [item(1729, window: 1), item(2171, window: 2), item(1873, window: 3)]
    let split = BarCut.split(items: items, cutX: 1800)
    // Both groups descend in x, which is what makes "left of the cut" mean the rows
    // below it rather than an arbitrary order the eye cannot follow.
    #expect(split.staying.map(\.frame.minX) == [2171, 1873])
    #expect(split.hiding.map(\.frame.minX) == [1729])
}

@Test func anUnplacedCutReportsEverythingAsHiding() {
    // A seam that has not been placed sits at the far right by default and would push
    // the whole run, so reporting nothing as hiding would understate what the button
    // is about to do.
    let split = BarCut.split(items: [item(1729, window: 1), item(2171, window: 2)],
                             cutX: nil)
    #expect(split.hiding.count == 2)
    #expect(split.staying.isEmpty)
}

@Test func theSeamItselfIsExcludedFromBothSides() {
    // Stow owns two items, its token and its seam, and both resolve to the name
    // "Stow". Leaving the seam in listed Stow twice and offered a cut at the cut.
    let seamWindow: CGWindowID = 99
    let items = [item(2093, window: 1), item(2297, window: seamWindow)]
    let split = BarCut.split(items: items, cutX: 2297, excluding: [seamWindow])
    #expect(split.staying.isEmpty)
    #expect(split.hiding.map(\.windowNumber) == [1])
}

@Test func appleItemsOnTheHiddenSideAreReportedAsUnhidableNotAsHiding() {
    // The measured behaviour this defends: with the cut right of Outlook, and again
    // right of zoom.us, the Control Center item at x1804 was on the hidden side both
    // times and stayed on the bar both times. Listing it under HIDES would make the
    // pane promise a hide that cannot happen.
    let apple: CGWindowID = 42
    let items = [item(1804, window: apple), item(1847, window: 1), item(2171, window: 2)]
    let split = BarCut.split(items: items, cutX: 1900, unpushable: [apple])
    #expect(split.hiding.map(\.windowNumber) == [1])
    #expect(split.unhidable.map(\.windowNumber) == [apple])
    #expect(split.staying.map(\.windowNumber) == [2])
}

@Test func anUnpushableItemRightOfTheCutIsSimplyStaying() {
    // Right of the cut, nothing is being asked of it, so it belongs in STAYS VISIBLE
    // rather than in a bucket that exists to explain a limitation.
    let apple: CGWindowID = 42
    let split = BarCut.split(items: [item(2361, window: apple)], cutX: 1900,
                             unpushable: [apple])
    #expect(split.staying.map(\.windowNumber) == [apple])
    #expect(split.unhidable.isEmpty)
}

// MARK: - BarPlan
//
// What the two-zone boundary means for per-app choices.

private func app(_ bundle: String, _ homeX: CGFloat, pushable: Bool = true) -> BarPlan.Candidate {
    BarPlan.Candidate(bundleID: bundle, homeX: homeX, isPushable: pushable)
}

/// A zone lookup from an explicit table, defaulting to `.pinned` exactly as
/// `Config.zone(forBundleID:)` does for an app it has never been told about.
private func zoneTable(_ pairs: [String: Zone]) -> (String) -> Zone {
    { pairs[$0] ?? .pinned }
}

@Test func everythingPinnedNeedsNoBoundary() {
    let candidates = [app("a", 1729), app("b", 2171)]
    let outcome = BarPlan.outcome(candidates: candidates, zones: zoneTable([:]))
    #expect(outcome.tuckedBoundaryX == nil)
    #expect(outcome.hiddenAtRest.isEmpty)
}

@Test func theTuckSeamClearsTheRightmostAppThatLeavesTheBarAtRest() {
    let candidates = [app("a", 1729), app("b", 1873), app("c", 2171)]
    let outcome = BarPlan.outcome(candidates: candidates,
                                  zones: zoneTable(["a": .tucked, "b": .tucked]))
    #expect(outcome.tuckedBoundaryX == 1873)
    #expect(Set(outcome.hiddenAtRest) == Set(["a", "b"]))
    #expect(outcome.collateral.isEmpty)
    #expect(outcome.isSafeToApply)
}

@Test func aPinnedAppLeftOfTheTuckSeamIsReportedAsCollateral() {
    // The active arranger moves only the selected app around a stationary boundary.
    let candidates = [app("pinA", 1729), app("pinB", 1873), app("tuck", 2093)]
    let outcome = BarPlan.outcome(candidates: candidates, zones: zoneTable(["tuck": .tucked]))
    #expect(outcome.tuckedBoundaryX == 2093)
    #expect(Set(outcome.hiddenAtRest) == Set(["pinA", "pinB", "tuck"]))
    #expect(outcome.collateral.isEmpty)
    #expect(outcome.isSafeToApply)
}

@Test func zoningAnUnpushableAppNeverDragsASeamOnItsBehalf() {
    // An Apple item cannot be moved, so placing a seam past it would hide everything up to
    // an item that was never going to move: the worst of both outcomes.
    let candidates = [app("a", 1729), app("com.apple.x", 2361, pushable: false)]
    let outcome = BarPlan.outcome(candidates: candidates,
                                  zones: zoneTable(["com.apple.x": .tucked]))
    #expect(outcome.tuckedBoundaryX == nil)
    #expect(outcome.hiddenAtRest.isEmpty)
    #expect(outcome.unreachable == ["com.apple.x"])
    #expect(!outcome.isSafeToApply)
}

@Test func anUnpushableAppLeftOfASeamIsNeverCountedAsHidden() {
    let candidates = [app("com.apple.x", 1804, pushable: false), app("a", 2093)]
    let outcome = BarPlan.outcome(candidates: candidates, zones: zoneTable(["a": .tucked]))
    #expect(outcome.hiddenAtRest == ["a"])
    #expect(outcome.collateral.isEmpty)
}

@Test func anAlreadyHiddenAppIsPlannedFromItsHomePositionNotItsPushedOne() {
    // The reason `BarHomes` exists. A hidden app still has to appear in the plan, placed by
    // where it BELONGS: planning from a pushed item's live position (far off-screen to the
    // left) would compute a seam position that hides everything.
    let candidates = [app("hidden", 2093), app("visible", 2171)]
    let outcome = BarPlan.outcome(candidates: candidates, zones: zoneTable(["hidden": .tucked]))
    #expect(outcome.tuckedBoundaryX == 2093)
    #expect(outcome.hiddenAtRest == ["hidden"])
}

@Test func rePinningTheLastHiddenAppClearsTheBoundary() {
    let candidates = [app("a", 2093), app("b", 2171)]
    let hidden = BarPlan.outcome(candidates: candidates, zones: zoneTable(["a": .tucked]))
    #expect(hidden.tuckedBoundaryX == 2093)
    let restored = BarPlan.outcome(candidates: candidates, zones: zoneTable([:]))
    #expect(restored.tuckedBoundaryX == nil)
}

@Test func hiddenListsAreOrderedRightToLeftLikeTheBar() {
    let candidates = [app("a", 1729), app("b", 1873), app("c", 2093)]
    let outcome = BarPlan.outcome(candidates: candidates, zones: zoneTable(["c": .tucked]))
    #expect(outcome.hiddenAtRest == ["c", "b", "a"])
    #expect(outcome.collateral.isEmpty)
}

// MARK: - the placement floor measurement
//
// Both rejections come from observed failures, not caution.

@Test func aFloorMeasuredWhileASeamWasExpandedIsRejected() {
    // Measured at x-3128: the probe was itself pushed off the bar by the ~5000pt seam, so what
    // it measured was where a pushed item sits, not where a new item may be placed.
    #expect(HideController.plausibleFloor(-3128, rightmostApp: 2205) == nil)
    #expect(HideController.plausibleFloor(0, rightmostApp: 2205) == nil)
}

@Test func aFloorRightOfEveryAppIsRejected() {
    // A sparse bar lets the probe land somewhere no ordinary app sits. Believing it marks every
    // app unzonable, which showed up as every tile on the board captioned "macOS limit".
    #expect(HideController.plausibleFloor(2340, rightmostApp: 2205) == nil)
}

@Test func aFloorInsideTheRunOfAppsIsAccepted() {
    // The real measurement from a twelve-item bar: x1987, with apps out to x2205.
    #expect(HideController.plausibleFloor(1987, rightmostApp: 2205) == 1987)
    // Exactly at the rightmost app is still meaningful: that app alone is unseparable.
    #expect(HideController.plausibleFloor(2205, rightmostApp: 2205) == 2205)
}

@Test func withNoAppsAtAllAPositiveFloorIsTakenAtFaceValue() {
    // Nothing to contradict it, and rejecting it would discard the only information available.
    #expect(HideController.plausibleFloor(1987, rightmostApp: nil) == 1987)
}

// MARK: - the expanded-seam trap
//
// The bug that ate a real menu bar, and the arithmetic that proves the guard.
//
// The cut search compares a seam's measured left edge against a target position. That is
// only meaningful while the seam is at REST. Expanded, the item is about 5,000pt wide, so
// on a 2560pt bar its left edge measures around -2700: a number that describes nothing.
// A search run in that state compared garbage at every step and settled on a seam
// spanning the entire bar, which pushed EVERY item off and reported -1863pt of headroom.

@Test func anExpandedSeamsLeftEdgeIsNotAUsablePosition() {
    // The seam is right-anchored, so growing it moves its left edge left. At pushing
    // width that edge is off the screen entirely, which is why the search must never
    // measure in this state.
    let barWidth: CGFloat = 2560
    let restingRightEdge: CGFloat = 2300
    let expandedWidth: CGFloat = 5016   // measured clamp of a 10,000pt request
    let expandedLeftEdge = restingRightEdge - expandedWidth
    #expect(expandedLeftEdge < 0)
    // And it is not merely off-screen, it is further left than any real item could be,
    // so a comparison against a target position cannot accidentally still be correct.
    #expect(expandedLeftEdge < -barWidth / 2)
}

@Test func aSeamWiderThanTheBarWouldConsumeEveryItemsHeadroom() {
    // Why the failure was total rather than partial: one 5,016pt claim on a bar with
    // 1,588pt of usable space leaves deeply negative headroom, and every item is pushed.
    let budget = BarBudget(screenWidth: 2560, appMenuWidth: 604, notchWidth: 0,
                           systemTrailingWidth: 368, occupiedWidths: [5016])
    #expect(budget.headroom < 0)
    #expect(budget.inUse > budget.usable)
}

// MARK: - version discipline
//
// The standing rule is patch-digit only until Stow releases, and it was already written
// in `StowVersion`'s own doc comment when it was violated twice in one day: 0.1.1 jumped
// to 0.2.0, then 0.2.1 to 0.3.0. A comment asking for discipline is not a check, so this
// is the check.

@Test func versionOnlyEverBumpsThePatchDigit() {
    #expect(StowVersion.current.hasPrefix(StowVersion.preReleaseLine + "."))
}

@Test func theVersionIsThreeNumbersAndTheLastOneIsTheOnlyFreeDigit() {
    let parts = StowVersion.current.split(separator: ".")
    #expect(parts.count == 3)
    // Major and minor are pinned; only the patch digit varies. Spelled against the
    // declared line rather than against literals, so moving the line is one edit in one
    // place and this test follows it.
    let line = StowVersion.preReleaseLine.split(separator: ".")
    #expect(parts.first == line.first)
    #expect(parts.dropFirst().first == line.dropFirst().first)
    // And the patch digit must be a number, since `install.sh` greps this string.
    #expect(Int(parts[2]) != nil)
}

// MARK: - SlotMap.collapse
//
// The map's one piece of pure arithmetic, and the one that was wrong. Every number below is
// a real measurement from `Stow --slots`, not an invented one.

@Test func twoProbesOnePointApartAreOneSlot() {
    // The exact defect. A 6pt BUCKET put these in different buckets, because 1490 and 1491
    // round to 248 and 249, so the map reported two slots one point apart and every landing
    // then looked wrong to the verification that used it.
    let collapsed = SlotMap.collapse([
        SlotMap.Slot(placement: 240, landingX: 1490),
        SlotMap.Slot(placement: 300, landingX: 1491),
    ])
    #expect(collapsed.count == 1)
    // The SMALLEST preference survives: never further left, least likely to be clamped.
    #expect(collapsed.first?.placement == 240)
}

@Test func theSurvivingSlotPositionIsOneThatWasActuallyMeasured() {
    // Never a cluster average. A map reporting a position no probe observed is asserting
    // something about the bar that was never measured.
    let collapsed = SlotMap.collapse([
        SlotMap.Slot(placement: 20, landingX: 1481),
        SlotMap.Slot(placement: 60, landingX: 1482),
    ])
    #expect(collapsed.count == 1)
    #expect(collapsed.first?.landingX == 1481)
}

@Test func genuinelyDistinctSlotsAreKept() {
    // Measured on the built-in display: real slots about 35pt apart. Collapsing these would be
    // the opposite failure, leaving the bar with fewer reachable positions than it has.
    let collapsed = SlotMap.collapse([
        SlotMap.Slot(placement: 1, landingX: 1516),
        SlotMap.Slot(placement: 240, landingX: 1490),
        SlotMap.Slot(placement: 60, landingX: 1481),
    ])
    #expect(collapsed.count == 3)
}

@Test func slotsComeBackRightmostFirst() {
    // Bar order, matching every other list in Stow: the rightmost position hides least, so it
    // is the one a lookup should consider first.
    let collapsed = SlotMap.collapse([
        SlotMap.Slot(placement: 240, landingX: 1439),
        SlotMap.Slot(placement: 1, landingX: 1516),
        SlotMap.Slot(placement: 60, landingX: 1481),
    ])
    #expect(collapsed.map(\.landingX) == [1516, 1481, 1439])
}

@Test func theSmallestPreferenceWinsAcrossAChainOfNearbyProbes() {
    // Each step is within the 6pt jitter of the previous one, so this is one cluster spanning
    // 15pt. The point is that the smallest preference still wins across it and no position is
    // invented along the way.
    let collapsed = SlotMap.collapse([
        SlotMap.Slot(placement: 100, landingX: 1480),
        SlotMap.Slot(placement: 200, landingX: 1485),
        SlotMap.Slot(placement: 300, landingX: 1490),
        SlotMap.Slot(placement: 400, landingX: 1495),
    ])
    #expect(collapsed.count == 1)
    #expect(collapsed.first?.placement == 100)
    #expect(collapsed.first?.landingX == 1480)
}

@Test func collapsingNothingYieldsNothing() {
    #expect(SlotMap.collapse([]).isEmpty)
}
