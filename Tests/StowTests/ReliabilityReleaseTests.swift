import Foundation
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

@Test func itemMoverRetriesOnlyBeforeItsThirdAttempt() {
    #expect(ItemMover.shouldRetry(after: 1))
    #expect(ItemMover.shouldRetry(after: 2))
    #expect(!ItemMover.shouldRetry(after: 3))
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

@Test @MainActor func aSuccessfulTransactionMovesEverythingAndVerifiesOnce() {
    var events: [String] = []
    let outcome = BarArranger.executeTransaction(
        moves: [transactionMove("a", window: 1), transactionMove("b", window: 2)],
        perform: { move, _, phase in
            events.append("\(phase)-\(move.bundleID)")
            return nil
        },
        verify: {
            events.append("verify")
            return []
        })

    #expect(outcome.moved == ["a", "b"])
    #expect(outcome.failed.isEmpty)
    #expect(!outcome.rolledBack)
    #expect(events == ["apply-a", "apply-b", "verify"])
}

@Test @MainActor func aPartialMoveFailureRollsBackCompletedMovesInReverse() {
    var events: [String] = []
    let outcome = BarArranger.executeTransaction(
        moves: [transactionMove("a", window: 1), transactionMove("b", window: 2)],
        perform: { move, _, phase in
            events.append("\(phase)-\(move.bundleID)")
            if phase == .apply, move.bundleID == "b" {
                return transactionFailure("b", "move refused")
            }
            return nil
        },
        verify: {
            Issue.record("verification must not run after a move failure")
            return []
        })

    #expect(outcome.moved.isEmpty)
    #expect(outcome.failed.first?.bundleID == "b")
    #expect(outcome.rolledBack)
    #expect(events == ["apply-a", "apply-b", "rollback-a"])
}

@Test @MainActor func verificationFailureRollsBackEveryMoveInReverse() {
    var events: [String] = []
    let outcome = BarArranger.executeTransaction(
        moves: [transactionMove("a", window: 1), transactionMove("b", window: 2)],
        perform: { move, _, phase in
            events.append("\(phase)-\(move.bundleID)")
            return nil
        },
        verify: {
            events.append("verify")
            return [transactionFailure("b", "window disappeared")]
        })

    #expect(outcome.moved.isEmpty)
    #expect(outcome.rolledBack)
    #expect(events == ["apply-a", "apply-b", "verify", "rollback-b", "rollback-a"])
}

@Test @MainActor func rollbackFailureIsReportedWithoutClaimingSuccess() {
    let outcome = BarArranger.executeTransaction(
        moves: [transactionMove("a", window: 1)],
        perform: { move, _, phase in
            if phase == .rollback {
                return transactionFailure(move.bundleID, "rollback refused")
            }
            return nil
        },
        verify: { [transactionFailure("a", "wrong side")] })

    #expect(outcome.moved.isEmpty)
    #expect(outcome.failed.map(\.reason) == ["wrong side", "rollback refused"])
    #expect(outcome.rolledBack)
}

@Test @MainActor func preflightFailureMakesNoMoveAndDoesNotVerify() {
    var touched = false
    let outcome = BarArranger.executeTransaction(
        moves: [transactionMove("a", window: 1)],
        initialFailures: [transactionFailure(nil, "unknown hidden item")],
        perform: { _, _, _ in
            touched = true
            return nil
        },
        verify: {
            touched = true
            return []
        })

    #expect(!touched)
    #expect(outcome.failed.count == 1)
    #expect(!outcome.rolledBack)
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
