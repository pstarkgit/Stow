import CoreGraphics
import Foundation
import Testing
@testable import Stow

// Tests for the Shelf model: Stow reads which side of its boundary every icon is on, records
// the user's decisions, and points out drift. It never moves an icon, so everything here is
// pure arithmetic over identities and window frames.

private let own = "dev.starkpat.stow"

private func owner(_ bundle: String, x: CGFloat, name: String? = nil) -> BarItemOwners.Owner {
    BarItemOwners.Owner(name: name ?? bundle, bundleID: bundle, pid: 1, axLeftEdge: x)
}

private func window(_ id: CGWindowID, x: CGFloat, width: CGFloat = 36) -> ObservedItem {
    ObservedItem(windowNumber: id, ownerPID: 1, bundleID: nil, ownerName: "Control Center",
                 frame: CGRect(x: x, y: 0, width: width, height: 33), isOnScreen: x >= 0)
}

// MARK: - which side an icon is on

@Test func aPushedItemWithARealWindowIsHidden() {
    let layout = HideController.liveLayout(
        identities: [owner("us.zoom.xos", x: -3993)],
        windows: [window(81, x: -3991)],
        cutX: nil, presentation: .tidy, ownBundle: own)
    #expect(layout.map(\.bundleID) == ["us.zoom.xos"])
    #expect(layout[0].isHidden)
}

@Test func aPushedItemWithoutAWindowIsNotListed() {
    // macOS dropped the item entirely; there is nothing on the shelf to open.
    let layout = HideController.liveLayout(
        identities: [owner("us.zoom.xos", x: -3993)],
        windows: [],
        cutX: nil, presentation: .tidy, ownBundle: own)
    #expect(layout.isEmpty)
}

@Test func theSentinelPositionIsNeverASide() {
    let layout = HideController.liveLayout(
        identities: [owner("com.amazon.ACME", x: -1), owner("com.microsoft.OneDrive", x: 1200)],
        windows: [window(1, x: -3930)],
        cutX: 1100, presentation: .everything, ownBundle: own)
    #expect(layout.map(\.bundleID) == ["com.microsoft.OneDrive"])
}

@Test func whileEverythingIsShownLeftOfTheBoundaryMeansStowed() {
    let layout = HideController.liveLayout(
        identities: [owner("a", x: 900), owner("b", x: 1150), owner("c", x: 1300)],
        windows: [],
        cutX: 1200, presentation: .everything, ownBundle: own)
    #expect(layout.map(\.bundleID) == ["a", "b", "c"], "bar order, left to right")
    #expect(layout.map(\.isHidden) == [true, true, false])
}

@Test func whileHiddenAVisiblePositionIsNeverStowed() {
    // In the tidy presentation the boundary is 10,000pt wide, so anything still at a positive x
    // is on the visible side by definition; the stale resting cut must not reclassify it.
    let layout = HideController.liveLayout(
        identities: [owner("a", x: 900)],
        windows: [],
        cutX: 1200, presentation: .tidy, ownBundle: own)
    #expect(layout.map(\.isHidden) == [false])
}

@Test func stowsOwnTokenAndControlCenterAreNotEntries() {
    let layout = HideController.liveLayout(
        identities: [owner(own, x: 1400), owner("com.apple.controlcenter", x: 1500, name: "Clock"),
                     owner("com.microsoft.OneDrive", x: 1300)],
        windows: [],
        cutX: 1100, presentation: .everything, ownBundle: own)
    #expect(layout.map(\.bundleID) == ["com.microsoft.OneDrive"])
}

@Test func aMultiItemAppIsListedOnce() {
    let layout = HideController.liveLayout(
        identities: [owner("com.bjango.istatmenus.status", x: 1000),
                     owner("com.bjango.istatmenus.status", x: 1040),
                     owner("com.bjango.istatmenus.status", x: 1080)],
        windows: [],
        cutX: 1200, presentation: .everything, ownBundle: own)
    #expect(layout.count == 1)
}

// MARK: - notices

@Test func aStowedAppBackOnTheVisibleSideIsADriftNotice() {
    var config = Config.default
    config.setZone(.tucked, forBundleID: "us.zoom.xos")
    let notices = HideController.layoutNotices(config: config, hidden: [], visible: ["us.zoom.xos"],
                                               dismissed: [])
    #expect(notices == [.init(bundleID: "us.zoom.xos", kind: .backOnBar)])
}

@Test func aPinnedAppThatEndedUpStowedIsADriftNotice() {
    var config = Config.default
    config.setZone(.pinned, forBundleID: "com.microsoft.OneDrive")
    let notices = HideController.layoutNotices(config: config, hidden: ["com.microsoft.OneDrive"],
                                               visible: [], dismissed: [])
    #expect(notices == [.init(bundleID: "com.microsoft.OneDrive", kind: .slippedIntoStow)])
}

@Test func anUnrecordedVisibleAppIsANewAppNoticeOnlyOnceDecisionsExist() {
    // First run: nothing recorded, so nothing is "new". Prompting for every app would be noise.
    let fresh = HideController.layoutNotices(config: Config.default, hidden: [],
                                             visible: ["com.example.new"], dismissed: [])
    #expect(fresh.isEmpty)

    var config = Config.default
    config.setZone(.tucked, forBundleID: "us.zoom.xos")
    let later = HideController.layoutNotices(config: config, hidden: ["us.zoom.xos"],
                                             visible: ["com.example.new"], dismissed: [])
    #expect(later == [.init(bundleID: "com.example.new", kind: .newApp)])
}

@Test func aDismissedNoticeStaysDismissed() {
    var config = Config.default
    config.setZone(.tucked, forBundleID: "us.zoom.xos")
    let notices = HideController.layoutNotices(config: config, hidden: [], visible: ["us.zoom.xos"],
                                               dismissed: ["us.zoom.xos"])
    #expect(notices.isEmpty)
}

@Test func anAppWhereTheUserLeftItProducesNoNotice() {
    var config = Config.default
    config.setZone(.tucked, forBundleID: "us.zoom.xos")
    config.setZone(.pinned, forBundleID: "com.microsoft.OneDrive")
    let notices = HideController.layoutNotices(config: config, hidden: ["us.zoom.xos"],
                                               visible: ["com.microsoft.OneDrive"], dismissed: [])
    #expect(notices.isEmpty)
}

// MARK: - a profile is a boundary width

@Test func pushWidthConsumesFreeSpaceThenTheItemsToHide() {
    // Everything left of the boundary shifts by its width, and an item leaves the bar only once
    // the free space before the app menus is used up. So free space comes first, then the items.
    #expect(HideController.pushWidth(hiding: [36, 40], headroom: 120) == CGFloat(36 + 40 + 120 + 4))
}

@Test func negativeHeadroomDoesNotShrinkThePush() {
    // A bar macOS is already clipping has no free space to consume, not negative space.
    #expect(HideController.pushWidth(hiding: [36], headroom: -300) == CGFloat(36 + 4))
}

@Test func nothingToHideMeansTheBoundaryRests() {
    #expect(HideController.pushWidth(hiding: [], headroom: 500) == SpacerItem.restingLength)
}

// MARK: - recording decisions

@Test @MainActor func recordingObservedZonesUpdatesOnlyTheNamedApps() {
    var fixture = Config.default
    fixture.zoneByBundleID = ["a": .tucked, "b": .pinned]
    let store = Store(fixtureConfig: fixture)

    store.recordObservedZones(["b": .tucked, "c": .pinned])

    #expect(store.config.zone(forBundleID: "a") == .tucked, "an app the bar did not report keeps its record")
    #expect(store.config.zone(forBundleID: "b") == .tucked)
    #expect(store.config.zone(forBundleID: "c") == .pinned)
}

@Test @MainActor func recordingObservedZonesFollowsTheActiveProfile() {
    var fixture = Config.default
    fixture.zoneByBundleID = ["a": .tucked]
    let store = Store(fixtureConfig: fixture)
    store.ensureProfileLayouts(candidateOrder: ["a", "b"])
    let focusBefore = store.profiles.first { $0.id == "focus" }

    store.recordObservedZones(["b": .tucked])

    let active = store.profiles.first { $0.id == store.config.activeProfileID }
    #expect(active?.appZones?["b"] == .tucked)
    #expect(store.profiles.first { $0.id == "focus" } == focusBefore, "other profiles are untouched")
}

// MARK: - the source no longer knows how to drag

@Test func noSourceFileSynthesisesAMouseEvent() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/Stow")
    let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("CGEvent(mouseEventSource"), "\(file.lastPathComponent) synthesises a mouse event")
        #expect(!text.contains("CGWarpMouseCursorPosition"), "\(file.lastPathComponent) moves the cursor")
        #expect(!text.contains("CGDisplayHideCursor"), "\(file.lastPathComponent) hides the cursor")
    }
}


// MARK: - Arrange interaction stability

@Test func arrangeOnlyRefreshesWhenTheUserAsks() throws {
    let pane = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/Stow/ArrangePane.swift")
    let source = try String(contentsOf: pane, encoding: .utf8)

    #expect(source.contains("Button(\"Refresh Bar\", action: refreshBar)"))
    #expect(source.contains("plannedStowBundleIDs"),
            "Arrange keeps an explicit user-chosen Stow setup list separate from current placement")
    #expect(source.contains("TO STOW"))
    #expect(source.contains("1 Pick here  ·  2 Drag in the actual menu bar  ·  3 Refresh Bar to check."))
    #expect(source.contains("Picking never moves an icon."))
    #expect(!source.contains("while !Task.isCancelled"),
            "Arrange must not replace its tiles on a timer while the user is interacting")
    #expect(!source.contains("Task.sleep(for: .seconds(1))"))
}
