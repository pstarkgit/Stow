import Foundation
import CoreGraphics
import Testing
@testable import Stow

// MARK: - Boundary launch lifecycle

@Test func persistentBoundaryTracksItsRecordedPlacementAtCreation() {
    #expect(SpacerItem.initialPlacement(persistPlacement: true,
                                        recordedPlacement: 900,
                                        defaultPlacement: 8) == 900)
}

@Test func diagnosticBoundaryIgnoresTheLiveAppsRecordedPlacement() {
    #expect(SpacerItem.initialPlacement(persistPlacement: false,
                                        recordedPlacement: 900,
                                        defaultPlacement: 8) == 8)
}

// MARK: - Self-update lifecycle

@Test @MainActor func metadataOnlyMergeCommitDoesNotOfferAPointlessReinstall() async {
    let state = await Updater.decideCheck(installed: "installed") { args in
        switch args {
        case ["fetch", "--quiet", "origin", "main"]:
            return .exited(0, "", "")
        case ["rev-parse", "HEAD", "origin/main"]:
            // The checkout still names the reviewed feature commit while origin/main
            // names GitHub's merge commit. Their trees are identical below.
            return .exited(0, "installed\nremote", "")
        case ["rev-parse", "installed^{tree}", "remote^{tree}"]:
            return .exited(0, "same-tree\nsame-tree", "")
        case ["merge-base", "--is-ancestor", "remote", "installed"]:
            return .exited(1, "", "")
        case ["merge-base", "--is-ancestor", "installed", "remote"]:
            return .exited(0, "", "")
        case ["rev-list", "--count", "installed..remote"]:
            return .exited(0, "1", "")
        default:
            Issue.record("unexpected git invocation: \(args)")
            return .launchFailed
        }
    }

    guard case .upToDate = state else {
        Issue.record("an identical source tree must be current, got \(state)")
        return
    }
}

@Test func updaterReportsTheInstallerErrorInsteadOfTheRollbackStatus() throws {
    let log = FileManager.default.temporaryDirectory
        .appending(path: "stow-update-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    try """
    Signed with Developer ID + Hardened Runtime
    ERROR: the new Stow.app never started.
    Restored the previous Stow.app
    """.write(to: log, atomically: true, encoding: .utf8)

    #expect(Updater.lastLine(ofLogAt: log.path) == "the new Stow.app never started.")
}

@Test func installerForcesANewLaunchAfterStoppingTheOldProcess() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(contentsOf: root.appending(path: "install.sh"),
                            encoding: .utf8)

    #expect(script.contains(#"if ! open -n "$FINAL_APP"; then"#))
}

@Test func installerVerifiesTheExactReplacementProcess() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(contentsOf: root.appending(path: "install.sh"),
                            encoding: .utf8)

    #expect(script.contains(#"STOPPED_PIDS="$(pgrep -x Stow || true)""#))
    #expect(script.contains(#"kill -0 "$NEW_PID""#))
}

@Test func installerResolvesDuplicateDeveloperIDNamesToAUniqueFingerprint() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(contentsOf: root.appending(path: "install.sh"),
                            encoding: .utf8)

    #expect(script.contains(#"DEVID_HASH="$("#))
    #expect(script.contains(#"--sign "$DEVID_HASH" "$APP""#))
}

@Test func itemMoverRetriesOnlyBeforeItsThirdAttempt() {
    #expect(ItemMover.shouldRetry(after: 1))
    #expect(ItemMover.shouldRetry(after: 2))
    #expect(!ItemMover.shouldRetry(after: 3))
}

@Test func multiItemAppMovesBesideItsSiblingOnTheRequestedSide() {
    let layout: [(windowID: CGWindowID, bundleID: String?)] = [
        (7311, "eu.exelban.Stats"),
        (1032, "com.amazon.kiro.crew"),
        (6683, "com.openai.codex"),
        (30, "com.apple.KerberosMenuExtra"),
        (155, "com.microsoft.OneDrive"),
        (7318, "dev.starkpat.stow"),
        (7192, "eu.exelban.Stats"),
        (7190, "eu.exelban.Stats"),
        (7195, "eu.exelban.Stats"),
    ]

    #expect(BarArranger.siblingAnchor(bundleID: "eu.exelban.Stats",
                                      wantsRight: true,
                                      seamIndex: 5,
                                      items: layout) == 7192)
}

@Test func multiItemAppCrossesTheBoundaryNearestFirstAndChainsItsOwnOrder() {
    let bundleID = "com.bjango.istatmenus.status"
    let layout: [(windowID: CGWindowID, bundleID: String?)] = [
        (1095, bundleID),
        (1096, bundleID),
        (1094, bundleID),
        (1092, bundleID),
        (1091, bundleID),
        (1093, bundleID),
        (1133, "dev.starkpat.stow"),
    ]
    let moves = layout.prefix(6).map { item in
        BarArranger.TransactionMove(
            bundleID: bundleID,
            windowID: item.windowID,
            hostPID: 1,
            wantsRight: true)
    }

    let planned = BarArranger.movementPlan(
        moves: moves,
        seamIndex: 6,
        items: layout)

    #expect(planned.map(\.windowID) == [1093, 1091, 1092, 1094, 1096, 1095])
    #expect(planned.map(\.siblingAnchorID) == [nil, 1093, 1091, 1092, 1094, 1096])
}

@Test func itemMoverDoesNotAcceptOneTransientCorrectFrameAsSettled() {
    #expect(!ItemMover.positionIsStable(correctSamples: 1))
    #expect(!ItemMover.positionIsStable(correctSamples: 9))
    #expect(ItemMover.positionIsStable(correctSamples: 10))
}

@Test func boundaryIdentityUsesWidthWhenANeighbourSharesItsReportedX() {
    let seam = ObservedItem(windowNumber: 10, ownerPID: 1, bundleID: nil,
                            ownerName: "Control Center",
                            frame: CGRect(x: 1146, y: 0, width: 17, height: 33),
                            isOnScreen: true)
    let neighbour = ObservedItem(windowNumber: 11, ownerPID: 1, bundleID: nil,
                                 ownerName: "Control Center",
                                 frame: CGRect(x: 1163, y: 0, width: 38, height: 33),
                                 isOnScreen: true)

    let match = SpacerItem.matchingWindow(
        in: [neighbour, seam],
        ownFrame: CGRect(x: 1163, y: 0, width: 17, height: 33))

    #expect(match?.windowNumber == seam.windowNumber)
}

@Test func boundaryIdentityRejectsANearbyWindowWithTheWrongWidth() {
    let neighbour = ObservedItem(windowNumber: 11, ownerPID: 1, bundleID: nil,
                                 ownerName: "Control Center",
                                 frame: CGRect(x: 1163, y: 0, width: 38, height: 33),
                                 isOnScreen: true)

    #expect(SpacerItem.matchingWindow(
        in: [neighbour],
        ownFrame: CGRect(x: 1163, y: 0, width: 17, height: 33)) == nil)
}

@Test @MainActor func anAppRefusalGetsOneFreshArrangementAttempt() {
    var attempts = 0
    var resets = 0
    let outcome = HideController.executeArrangementWithTransientRetry(
        perform: {
            attempts += 1
            if attempts == 1 {
                var failed = BarArranger.Outcome()
                failed.failed = [transactionFailure("com.example.app", "move refused")]
                return failed
            }
            return BarArranger.Outcome()
        },
        beforeRetry: { resets += 1 })

    #expect(attempts == 2)
    #expect(resets == 1)
    #expect(outcome.isClean)
}

@Test @MainActor func freshArrangementPassesConvergeAcrossTwoDifferentRefusals() {
    var attempts = 0
    var resets = 0
    let outcome = HideController.executeArrangementWithTransientRetry(
        perform: {
            attempts += 1
            if attempts < 3 {
                var partial = BarArranger.Outcome()
                partial.moved = [attempts == 1 ? "a" : "b"]
                partial.failed = [transactionFailure(
                    attempts == 1 ? "b" : "c",
                    "move refused")]
                return partial
            }
            return BarArranger.Outcome()
        },
        beforeRetry: { resets += 1 })

    #expect(attempts == 3)
    #expect(resets == 2)
    #expect(outcome.isClean)
}

@Test @MainActor func anEnvironmentalArrangeFailureIsNotRepeated() {
    var attempts = 0
    var resets = 0
    let outcome = HideController.executeArrangementWithTransientRetry(
        perform: {
            attempts += 1
            var failed = BarArranger.Outcome()
            failed.failed = [transactionFailure(nil, "Accessibility unavailable")]
            return failed
        },
        beforeRetry: { resets += 1 })

    #expect(attempts == 1)
    #expect(resets == 0)
    #expect(!outcome.isClean)
}

@Test func backgroundArrangementNeverGetsPointerAuthority() {
    #expect(HideController.ArrangementIntent.explicitUserAction.allowsPointerControl)
    #expect(!HideController.ArrangementIntent.background.allowsPointerControl)
}

@Test func launchRestoresPresentationWithoutCallingTheSyntheticArranger() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "Sources/Stow/App.swift"),
                            encoding: .utf8)
    let launchStart = try #require(source.range(of: "Image(nsImage: StowGlyph.image"))
    let launchEnd = try #require(source.range(of: "// Quiet check at launch",
                                               range: launchStart.lowerBound..<source.endIndex))
    let launchPath = source[launchStart.lowerBound..<launchEnd.lowerBound]

    #expect(launchPath.contains("restorePresentationWithoutMoving"))
    #expect(!launchPath.contains("arrangeByMovingItems"))
}

@Test @MainActor func launchRestoreClearsATransientFalseNegativeWithoutMovingAnything() {
    var attempts = 0
    var waits = 0
    let restored = HideController.executeSafeRestoreChecks(
        perform: {
            attempts += 1
            return attempts == 2
        },
        beforeRetry: { waits += 1 })

    #expect(restored)
    #expect(attempts == 2)
    #expect(waits == 1)
}

@Test @MainActor func launchRestorePreservesTheFallbackForPersistentPhysicalDrift() {
    var attempts = 0
    var waits = 0
    let restored = HideController.executeSafeRestoreChecks(
        perform: {
            attempts += 1
            return false
        },
        beforeRetry: { waits += 1 })

    #expect(!restored)
    #expect(attempts == 2)
    #expect(waits == 1)
}

@Test func appLifecycleRefreshesDiscoveryWithoutRearrangingTheMenuBar() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "Sources/Stow/App.swift"),
                            encoding: .utf8)

    #expect(source.contains("NSWorkspace.didLaunchApplicationNotification"))
    #expect(source.contains("NSWorkspace.didTerminateApplicationNotification"))
    #expect(source.contains("hider.refreshCandidatesWithoutMoving()"))
    #expect(source.contains("hider.retryPendingSafeRestore(from: store.config)"))
    #expect(!source.contains("refreshCandidatesWithoutMoving().arrangeByMovingItems"))
}

@Test func compactPanelObservesTheLiveControllerInsteadOfCapturingLaunchScalars() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "Sources/Stow/App.swift"),
                            encoding: .utf8)

    #expect(source.contains("private struct LiveStatusPanel: View"))
    #expect(source.contains("@EnvironmentObject private var hider: HideController"))
    #expect(source.contains("arrangementFailures: hider.lastArrangeFailures"))
    #expect(source.contains("presentation: hider.presentation"))
    #expect(source.contains(".environmentObject(hider)"))
}

private func transactionMove(_ bundleID: String, window: UInt32) -> BarArranger.TransactionMove {
    BarArranger.TransactionMove(
        bundleID: bundleID,
        windowID: window,
        hostPID: 1,
        wantsRight: false)
}

private func transactionFailure(_ bundleID: String?, _ reason: String)
    -> BarArranger.Outcome.Failure {
    .init(bundleID: bundleID, reason: reason, recovery: "Recover.")
}

@Test @MainActor func aSuccessfulPassMovesEverythingAndVerifiesOnce() {
    var events: [String] = []
    let outcome = BarArranger.executePass(
        moves: [transactionMove("a", window: 1), transactionMove("b", window: 2)],
        perform: { move, _ in
            events.append("apply-\(move.bundleID)")
            return nil
        },
        verify: {
            events.append("verify")
            return []
        })

    #expect(outcome.moved == ["a", "b"])
    #expect(outcome.failed.isEmpty)
    #expect(events == ["apply-a", "apply-b", "verify"])
}

@Test @MainActor func aPartialMoveFailureKeepsVerifiedProgressForTheFreshRetry() {
    var events: [String] = []
    let outcome = BarArranger.executePass(
        moves: [transactionMove("a", window: 1), transactionMove("b", window: 2)],
        perform: { move, _ in
            events.append("apply-\(move.bundleID)")
            if move.bundleID == "b" {
                return transactionFailure("b", "move refused")
            }
            return nil
        },
        verify: {
            Issue.record("verification must not run after a move failure")
            return []
        })

    #expect(outcome.moved == ["a"])
    #expect(outcome.failed.first?.bundleID == "b")
    #expect(events == ["apply-a", "apply-b"])
}

@Test @MainActor func verificationFailureKeepsCompletedMovesForTheFreshRetry() {
    var events: [String] = []
    let outcome = BarArranger.executePass(
        moves: [transactionMove("a", window: 1), transactionMove("b", window: 2)],
        perform: { move, _ in
            events.append("apply-\(move.bundleID)")
            return nil
        },
        verify: {
            events.append("verify")
            return [transactionFailure("b", "window disappeared")]
        })

    #expect(outcome.moved == ["a", "b"])
    #expect(events == ["apply-a", "apply-b", "verify"])
}

@Test @MainActor func preflightFailureMakesNoMoveAndDoesNotVerify() {
    var touched = false
    let outcome = BarArranger.executePass(
        moves: [transactionMove("a", window: 1)],
        initialFailures: [transactionFailure(nil, "unknown hidden item")],
        perform: { _, _ in
            touched = true
            return nil
        },
        verify: {
            touched = true
            return []
        })

    #expect(!touched)
    #expect(outcome.failed.count == 1)
}

@Test func loadingLegacyZonesRewritesTheFileAndPreservesUnknownFields() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let original = Data(#"""
    {
      "zoneByBundleID": {"com.example.old": "vaulted"},
      "futureSetting": {"mode": "keep-me"}
    }
    """#.utf8)
    try original.write(to: url)

    let loaded = Config.load(from: url)
    #expect(loaded.zone(forBundleID: "com.example.old") == .tucked)

    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == Config.currentSchemaVersion)
    #expect((object["zoneByBundleID"] as? [String: String])?["com.example.old"] == "tucked")
    #expect((object["futureSetting"] as? [String: String])?["mode"] == "keep-me")
}

@Test func savingPreservesUnknownTopLevelAndProfileFields() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let original = Data(#"""
    {
      "futureSetting": 42,
      "profiles": [{
        "id": "presenting",
        "name": "Presenting",
        "spacerLength": 10,
        "tuckedRunDepth": 0,
        "hotkeyDisplay": "shortcut",
        "futureProfileField": "keep-me"
      }]
    }
    """#.utf8)
    try original.write(to: url)

    try Config.default.save(to: url)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    #expect(object["futureSetting"] as? Int == 42)
    let profiles = try #require(object["profiles"] as? [[String: Any]])
    let presenting = try #require(profiles.first { $0["id"] as? String == "presenting" })
    #expect(presenting["futureProfileField"] as? String == "keep-me")
}
