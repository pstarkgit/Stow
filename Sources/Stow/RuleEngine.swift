import AppKit
import Combine
import Foundation

/// Evaluates enabled frontmost-app rules and restores the prior profile when the app loses focus.
@MainActor
final class RuleEngine: ObservableObject {
    typealias RulesProvider = () -> [Config.Rule]
    typealias ActiveProfileProvider = () -> String?
    typealias ApplyProfile = (String) -> Bool

    struct Activity: Identifiable, Equatable, Codable, Sendable {
        enum Kind: String, Equatable, Codable, Sendable {
            case applied
            case restored
            case failed
            case manualOverride
            case cooldown
        }

        let id: UUID
        let timestamp: Date
        let kind: Kind
        let title: String
        let detail: String
        let ruleID: String?
        let bundleID: String?
        let profileID: String?
    }

    @Published private(set) var activeRuleID: String?
    @Published private(set) var lastStatus = "Watching for profile rules"
    @Published private(set) var activeReason = "Default active because no enabled rule matches"
    @Published private(set) var activities: [Activity] = []

    var isRunning: Bool { observer != nil }

    private var rulesProvider: RulesProvider = { [] }
    private var activeProfileProvider: ActiveProfileProvider = { nil }
    private var applyProfile: ApplyProfile = { _ in false }
    private var observer: NSObjectProtocol?
    private var previousProfileID: String?
    private var lastBundleID: String?
    private var manualOverrideBundleID: String?
    private var now: () -> Date = Date.init
    private var profileName: (String) -> String = { $0 }
    private var cooldown: TimeInterval = 2
    private var lastAppliedAt: [String: Date] = [:]
    private var historyURL: URL?
    private var historyLoaded = false
    private static let activityLimit = 20

    func start(
        rules: @escaping RulesProvider,
        activeProfileID: @escaping ActiveProfileProvider,
        applyProfile: @escaping ApplyProfile,
        now: @escaping () -> Date = Date.init,
        cooldown: TimeInterval = 2,
        profileName: @escaping (String) -> String = { $0 },
        historyURL: URL? = RuleEngine.defaultHistoryURL
    ) {
        configure(rules: rules, activeProfileID: activeProfileID,
                  applyProfile: applyProfile, now: now,
                  cooldown: cooldown, profileName: profileName,
                  historyURL: historyURL)
        loadHistory()
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
        applyProfile: @escaping ApplyProfile,
        now: @escaping () -> Date = Date.init,
        cooldown: TimeInterval = 2,
        profileName: @escaping (String) -> String = { $0 },
        historyURL: URL? = nil
    ) {
        rulesProvider = rules
        activeProfileProvider = activeProfileID
        self.applyProfile = applyProfile
        self.now = now
        self.cooldown = max(0, cooldown)
        self.profileName = profileName
        self.historyURL = historyURL
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func loadHistory() {
        guard !historyLoaded else { return }
        historyLoaded = true
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([Activity].self, from: data)
        else { return }
        activities = Array(decoded.prefix(Self.activityLimit))
    }

    nonisolated static var defaultHistoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Stow/rule-activity.json")
    }

    /// A manual profile choice wins until the user switches to another application.
    func noteManualSelection(
        selectedProfileID: String? = nil,
        bundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) {
        manualOverrideBundleID = bundleID
        activeRuleID = nil
        previousProfileID = nil
        lastStatus = "Manual profile override"
        let targetID = selectedProfileID ?? activeProfileProvider()
        let targetName = targetID.map(profileName) ?? "current profile"
        activeReason = "\(targetName) selected manually"
        record(kind: .manualOverride,
               title: "Selected \(targetName)",
               detail: bundleID.map { "Automation paused while \($0) stays frontmost" }
                   ?? "Automation paused for the current application",
               bundleID: bundleID,
               profileID: targetID)
    }

    func handleFrontmost(bundleID: String?) {
        if let override = manualOverrideBundleID, bundleID == override {
            lastBundleID = bundleID
            return
        }
        if manualOverrideBundleID != nil {
            manualOverrideBundleID = nil
            activeReason = "Default active because the manual override ended"
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
            let current = now()
            if let last = lastAppliedAt[match.id],
               current.timeIntervalSince(last) < cooldown {
                let remaining = max(0, cooldown - current.timeIntervalSince(last))
                lastStatus = "Rule cooling down"
                activeReason = "\(profileName(profileID)) waiting \(String(format: "%.1f", remaining))s"
                record(kind: .cooldown,
                       title: "Rule cooling down",
                       detail: "Ignored a repeated trigger for \(bundleID ?? "app")",
                       ruleID: match.id,
                       bundleID: bundleID,
                       profileID: profileID)
                return
            }
            if applyProfile(profileID) {
                activeRuleID = match.id
                lastAppliedAt[match.id] = current
                lastStatus = "Applied rule for \(bundleID ?? "app")"
                activeReason = "\(profileName(profileID)) active because \(bundleID ?? "an app") is frontmost"
                record(kind: .applied,
                       title: "Applied \(profileName(profileID))",
                       detail: "\(bundleID ?? "App") became frontmost",
                       ruleID: match.id,
                       bundleID: bundleID,
                       profileID: profileID)
            } else {
                lastStatus = "Rule could not apply its profile"
                activeReason = "\(profileName(profileID)) failed to apply"
                record(kind: .failed,
                       title: "Profile change failed",
                       detail: "Rule for \(bundleID ?? "app") could not apply \(profileName(profileID))",
                       ruleID: match.id,
                       bundleID: bundleID,
                       profileID: profileID)
            }
            return
        }

        guard activeRuleID != nil else {
            let current = activeProfileProvider().map(profileName) ?? "Default"
            activeReason = "\(current) active because no enabled rule matches"
            return
        }
        let endedRuleID = activeRuleID
        let restoreID = previousProfileID
        activeRuleID = nil
        previousProfileID = nil
        if let restoreID, applyProfile(restoreID) {
            lastStatus = "Restored previous profile"
            activeReason = "\(profileName(restoreID)) restored because no rule matches"
            record(kind: .restored,
                   title: "Restored \(profileName(restoreID))",
                   detail: "The automatic rule ended",
                   ruleID: endedRuleID,
                   bundleID: bundleID,
                   profileID: restoreID)
        } else {
            lastStatus = "Automatic profile ended"
            activeReason = "Default active because the automatic rule ended"
            record(kind: .failed,
                   title: "Previous profile was unavailable",
                   detail: "The automatic rule ended without a restorable profile",
                   ruleID: endedRuleID,
                   bundleID: bundleID,
                   profileID: restoreID)
        }
    }

    private func record(
        kind: Activity.Kind,
        title: String,
        detail: String,
        ruleID: String? = nil,
        bundleID: String? = nil,
        profileID: String? = nil
    ) {
        activities.insert(Activity(
            id: UUID(), timestamp: now(), kind: kind,
            title: title, detail: detail,
            ruleID: ruleID, bundleID: bundleID, profileID: profileID), at: 0)
        if activities.count > Self.activityLimit {
            activities.removeLast(activities.count - Self.activityLimit)
        }
        persistHistory()
    }

    private func persistHistory() {
        guard let historyURL,
              let data = try? JSONEncoder().encode(activities) else { return }
        try? FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }
}
