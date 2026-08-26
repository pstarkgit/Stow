import AppKit
import Combine
import Foundation

/// Evaluates enabled frontmost-app rules and restores the prior profile when the app loses focus.
@MainActor
final class RuleEngine: ObservableObject {
    typealias RulesProvider = () -> [Config.Rule]
    typealias ActiveProfileProvider = () -> String?
    typealias ApplyProfile = (String) -> Bool

    @Published private(set) var activeRuleID: String?
    @Published private(set) var lastStatus = "Watching for profile rules"

    private var rulesProvider: RulesProvider = { [] }
    private var activeProfileProvider: ActiveProfileProvider = { nil }
    private var applyProfile: ApplyProfile = { _ in false }
    private var observer: NSObjectProtocol?
    private var previousProfileID: String?
    private var lastBundleID: String?
    private var manualOverrideBundleID: String?

    func start(
        rules: @escaping RulesProvider,
        activeProfileID: @escaping ActiveProfileProvider,
        applyProfile: @escaping ApplyProfile
    ) {
        configure(rules: rules, activeProfileID: activeProfileID, applyProfile: applyProfile)
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main) { [weak self] note in
                    let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                                    as? NSRunningApplication)?.bundleIdentifier
                    Task { @MainActor in self?.handleFrontmost(bundleID: bundleID) }
                }
        }
        handleFrontmost(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func configure(
        rules: @escaping RulesProvider,
        activeProfileID: @escaping ActiveProfileProvider,
        applyProfile: @escaping ApplyProfile
    ) {
        rulesProvider = rules
        activeProfileProvider = activeProfileID
        self.applyProfile = applyProfile
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// A manual profile choice wins until the user switches to another application.
    func noteManualSelection(bundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
        manualOverrideBundleID = bundleID
        activeRuleID = nil
        previousProfileID = nil
        lastStatus = "Manual profile override"
    }

    func handleFrontmost(bundleID: String?) {
        if let override = manualOverrideBundleID, bundleID == override {
            lastBundleID = bundleID
            return
        }
        if manualOverrideBundleID != nil {
            manualOverrideBundleID = nil
        }
        lastBundleID = bundleID

        let match = rulesProvider().first { rule in
            guard rule.isEnabled else { return false }
            guard case .frontmostAppIs(let expected) = rule.condition else { return false }
            return expected == bundleID
        }

        if let match,
           case .applyProfile(let profileID) = match.action {
            if activeRuleID == nil { previousProfileID = activeProfileProvider() }
            guard activeRuleID != match.id || activeProfileProvider() != profileID else { return }
            if applyProfile(profileID) {
                activeRuleID = match.id
                lastStatus = "Applied rule for \(bundleID ?? "app")"
            } else {
                lastStatus = "Rule could not apply its profile"
            }
            return
        }

        guard activeRuleID != nil else { return }
        let restoreID = previousProfileID
        activeRuleID = nil
        previousProfileID = nil
        if let restoreID, applyProfile(restoreID) {
            lastStatus = "Restored previous profile"
        } else {
            lastStatus = "Automatic profile ended"
        }
    }
}
