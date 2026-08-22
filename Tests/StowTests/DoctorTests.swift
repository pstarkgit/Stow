import Testing
import CoreGraphics
@testable import Stow

private func doctorFinding(
    id: String,
    status: BarDoctor.Status
) -> BarDoctor.Finding {
    BarDoctor.Finding(id: id, title: id, detail: id, status: status, action: nil)
}

@Test func doctorSummaryCountsEveryCheckAndDoesNotCallPartialCoverageHealthy() {
    let findings = [
        doctorFinding(id: "access", status: .pass),
        doctorFinding(id: "pointmath", status: .pass),
        doctorFinding(id: "coverage", status: .info("partial")),
        doctorFinding(id: "hotkey", status: .pass),
        doctorFinding(id: "spacer", status: .pass),
    ]

    let summary = BarDoctor.summary(for: findings)

    #expect(summary.passCount == 4)
    #expect(summary.totalCount == 5)
    #expect(summary.issueCount == 1)
    #expect(summary.fraction == 0.8)
    #expect(summary.headline == "One check needs review")
}

@Test func doctorSummaryCallsACompletePassingRunHealthy() {
    let findings = [
        doctorFinding(id: "access", status: .pass),
        doctorFinding(id: "spacer", status: .pass),
    ]

    let summary = BarDoctor.summary(for: findings)

    #expect(summary.passCount == 2)
    #expect(summary.totalCount == 2)
    #expect(summary.fraction == 1)
    #expect(summary.headline == "All checks passed")
}

@Test @MainActor func spacerCheckPassesWhenTheLiveBoundaryHasAMeasuredWidth() {
    let finding = BarDoctor().checkSpacer(measuredWidth: 10)

    #expect(finding.status == .pass)
    #expect(finding.detail == "active, measured at 10 pt")
}

@Test @MainActor func spacerCheckWarnsWhenTheLiveBoundaryCannotBeMeasured() {
    let finding = BarDoctor().checkSpacer(measuredWidth: nil)

    #expect(finding.status == .warn("Restart Stow"))
    #expect(finding.detail == "boundary could not be measured")
}

@Test func builderAttributionCreditsGSDai() {
    #expect(StowVersion.builderAttribution == "built by GSD-ai")
}

@Test func pointMathExcludesStowsOwnExpandedBoundaryFromOccupiedSpace() {
    let seam = ObservedItem(windowNumber: 41, ownerPID: 1, bundleID: nil, ownerName: "Stow",
                            frame: CGRect(x: 100, y: 0, width: 5_000, height: 24),
                            isOnScreen: true)
    let app = ObservedItem(windowNumber: 42, ownerPID: 2, bundleID: nil, ownerName: "App",
                           frame: CGRect(x: 200, y: 0, width: 36, height: 24),
                           isOnScreen: true)

    let widths = BarDoctor.occupiedWidths(in: [seam, app], excluding: [41])

    #expect(widths == [36])
}

@Test func budgetExcludesAnExpandedBoundaryEvenWhenASeparateProcessDoesNotKnowItsWindowID() {
    let boundary = ObservedItem(windowNumber: 51, ownerPID: 1, bundleID: nil,
                                ownerName: "Control Center",
                                frame: CGRect(x: -3_000, y: 0, width: 5_016, height: 24),
                                isOnScreen: true)
    let app = ObservedItem(windowNumber: 52, ownerPID: 2, bundleID: nil,
                           ownerName: "App",
                           frame: CGRect(x: 1_200, y: 0, width: 42, height: 24),
                           isOnScreen: true)

    let widths = BarBudget.occupiedWidths(in: [boundary, app],
                                          screenWidth: 1_728,
                                          excluding: [])

    #expect(widths == [42])
}

@Test func standaloneRowsExcludeAnExpandedBoundaryFromPresentedItems() {
    let boundary = ObservedItem(windowNumber: 53, ownerPID: 1, bundleID: nil,
                                ownerName: "Control Center",
                                frame: CGRect(x: -3_000, y: 0, width: 5_016, height: 24),
                                isOnScreen: true)
    let app = ObservedItem(windowNumber: 54, ownerPID: 2, bundleID: nil,
                           ownerName: "App",
                           frame: CGRect(x: 1_200, y: 0, width: 42, height: 24),
                           isOnScreen: true)

    let items = BarBudget.ordinaryItems(in: [boundary, app],
                                        screenWidth: 1_728,
                                        excluding: [])

    #expect(items.map(\.windowNumber) == [54])
}

@Test @MainActor func coverageResolvesTuckedItemsAndExcludesTheSpacerMechanism() {
    let visible = ObservedItem(windowNumber: 61, ownerPID: 1, bundleID: nil,
                               ownerName: "Control Center",
                               frame: CGRect(x: 1_200, y: 0, width: 36, height: 24),
                               isOnScreen: true)
    let tucked = ObservedItem(windowNumber: 62, ownerPID: 1, bundleID: nil,
                              ownerName: "Control Center",
                              frame: CGRect(x: -3_966, y: 0, width: 34, height: 24),
                              isOnScreen: false)
    let spacer = ObservedItem(windowNumber: 63, ownerPID: 1, bundleID: nil,
                              ownerName: "Control Center",
                              frame: CGRect(x: -3_862, y: 0, width: 5_016, height: 24),
                              isOnScreen: true)
    let identities = [
        BarItemOwners.Owner(name: "Visible", bundleID: "com.example.visible",
                            pid: 101, axLeftEdge: 1_198),
        BarItemOwners.Owner(name: "Tucked", bundleID: "com.example.tucked",
                            pid: 102, axLeftEdge: -3_965),
    ]

    let split = BarDoctor.coverageSplit(subjects: [visible, tucked, spacer],
                                        identities: identities,
                                        screenWidth: 1_728,
                                        excluding: [63])

    #expect(split.resolved.map { $0.item.windowNumber } == [61, 62])
    #expect(split.resolved.map { $0.owner.pid } == [101, 102])
    #expect(split.unresolved.isEmpty)
}
