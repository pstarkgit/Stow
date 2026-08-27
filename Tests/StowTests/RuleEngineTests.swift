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

        engine.noteManualSelection(bundleID: "us.zoom.xos")
        engine.handleFrontmost(bundleID: "us.zoom.xos")
        #expect(applications == 0)

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
}
