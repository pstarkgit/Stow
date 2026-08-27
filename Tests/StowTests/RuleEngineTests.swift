import Foundation
import Testing
@testable import Stow

@Suite("Profile rule engine") @MainActor
struct RuleEngineTests {
    @Test func matchingFrontmostAppAppliesThenRestoresThePreviousProfile() {
        var activeProfile = "presenting"
        var applied: [String] = []
        let engine = RuleEngine()
        engine.configure(
            rules: {
                [.init(id: "zoom", isEnabled: true,
                       condition: .frontmostAppIs(bundleID: "us.zoom.xos"),
                       action: .applyProfile(id: "screen-share"))]
            },
            activeProfileID: { activeProfile },
            applyProfile: { id in
                activeProfile = id
                applied.append(id)
                return true
            })

        engine.handleFrontmost(bundleID: "us.zoom.xos")
        #expect(activeProfile == "screen-share")
        #expect(engine.activeRuleID == "zoom")

        engine.handleFrontmost(bundleID: "com.apple.finder")
        #expect(activeProfile == "presenting")
        #expect(engine.activeRuleID == nil)
        #expect(applied == ["screen-share", "presenting"])
    }

    @Test func manualSelectionWinsUntilTheFrontmostAppChanges() {
        var activeProfile = "presenting"
        var applications = 0
        let engine = RuleEngine()
        engine.configure(
            rules: {
                [.init(id: "zoom", isEnabled: true,
                       condition: .frontmostAppIs(bundleID: "us.zoom.xos"),
                       action: .applyProfile(id: "screen-share"))]
            },
            activeProfileID: { activeProfile },
            applyProfile: { id in
                activeProfile = id
                applications += 1
                return true
            })

        engine.noteManualSelection(selectedProfileID: "everything", bundleID: "us.zoom.xos")
        engine.handleFrontmost(bundleID: "us.zoom.xos")
        #expect(applications == 0)
        #expect(engine.activities.first?.profileID == "everything")
        #expect(engine.activities.first?.title == "Selected everything")

        engine.handleFrontmost(bundleID: "com.apple.finder")
        engine.handleFrontmost(bundleID: "us.zoom.xos")
        #expect(activeProfile == "screen-share")
        #expect(applications == 1)
    }

    @Test func disabledAndUnsupportedRulesNeverApply() {
        var applications = 0
        let engine = RuleEngine()
        engine.configure(
            rules: {
                [
                    .init(id: "disabled", isEnabled: false,
                          condition: .frontmostAppIs(bundleID: "us.zoom.xos"),
                          action: .applyProfile(id: "focus")),
                    .init(id: "unsupported", isEnabled: true,
                          condition: .screenSharingStarted,
                          action: .applyProfile(id: "screen-share")),
                ]
            },
            activeProfileID: { "presenting" },
            applyProfile: { _ in applications += 1; return true })

        engine.handleFrontmost(bundleID: "us.zoom.xos")
        #expect(applications == 0)
        #expect(engine.activeRuleID == nil)
    }

    @Test func activityExplainsApplyRestoreAndCooldown() {
        var activeProfile = "presenting"
        var current = Date(timeIntervalSince1970: 1_000)
        let engine = RuleEngine()
        engine.configure(
            rules: {
                [.init(id: "zoom", isEnabled: true,
                       condition: .frontmostAppIs(bundleID: "us.zoom.xos"),
                       action: .applyProfile(id: "screen-share"))]
            },
            activeProfileID: { activeProfile },
            applyProfile: { id in activeProfile = id; return true },
            now: { current },
            cooldown: 5,
            profileName: { $0 == "screen-share" ? "Screen Share" : "Default" })

        engine.handleFrontmost(bundleID: "us.zoom.xos")
        current.addTimeInterval(1)
        engine.handleFrontmost(bundleID: "com.apple.finder")
        current.addTimeInterval(1)
        engine.handleFrontmost(bundleID: "us.zoom.xos")

        #expect(engine.activities.map(\.kind) == [.cooldown, .restored, .applied])
        #expect(engine.activities.last?.title == "Applied Screen Share")
        #expect(engine.activeReason.contains("waiting"))
    }

    @Test func activityHistoryIsBoundedToTwentyRows() {
        let engine = RuleEngine()
        engine.configure(rules: { [] }, activeProfileID: { "presenting" },
                         applyProfile: { _ in true })

        for index in 0..<25 {
            engine.noteManualSelection(bundleID: "app.\(index)")
        }

        #expect(engine.activities.count == 20)
        #expect(engine.activities.first?.bundleID == "app.24")
        #expect(engine.activities.last?.bundleID == "app.5")
    }

    @Test func activityHistorySurvivesRelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-rule-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = RuleEngine()
        writer.configure(rules: { [] }, activeProfileID: { "presenting" },
                         applyProfile: { _ in true }, historyURL: url)
        writer.noteManualSelection(bundleID: "com.example.app")

        let reader = RuleEngine()
        reader.configure(rules: { [] }, activeProfileID: { "presenting" },
                         applyProfile: { _ in true }, historyURL: url)
        reader.loadHistory()

        #expect(reader.activities.count == 1)
        #expect(reader.activities.first?.kind == .manualOverride)
        #expect(reader.activities.first?.bundleID == "com.example.app")
    }
}
