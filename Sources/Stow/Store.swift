import AppKit
import Foundation

/// The persisted policy layer: loads `Config`, publishes it to SwiftUI, and saves
/// changes back to disk.
///
/// Per-app zone membership IS trackable now: `Config.zoneByBundleID` keys on bundle
/// id, which survives a relaunch because `BarItemOwners` recovers it from the owning
/// app itself rather than from the window server (see `Config`'s own header comment
/// for the full correction). What `Store` does not yet do is ACT on that membership:
/// reveal behaviour, spacer geometry, named profiles, and rule definitions are exposed
/// here exactly as `Config` persists them. A zone assignment DOES now take visible effect on the
/// bar: `Config.setZone(_:forBundleID:)` records it and `BarArranger` acts on it, via
/// `HideController.arrangeByMovingItems`. This used to say the engine downstream did not exist,
/// which was true when the file was written and is not now.
///
/// Rules remain persisted-only. Profiles are live: each owns a saved app-zone map, selecting one
/// applies that map to `Config`, and Arrange edits update only the active profile.
@MainActor
final class Store: ObservableObject {

    /// Debounce window between the last edit and the write actually hitting disk.
    /// A `Double` bound to `AuroraStepper` fires this on every chevron tap and every
    /// point of drag; writing the file on each one would mean dozens of disk writes
    /// per interaction for a value that only needs to be durable once the user stops
    /// touching it.
    private static let saveDebounce: Duration = .milliseconds(400)

    @Published var config: Config {
        didSet { scheduleSave() }
    }
    @Published private(set) var undoProfileID: String?

    /// The in-flight debounce, held as a `Task` rather than an `NSObjectProtocol`
    /// observer token or a `Timer`.
    ///
    /// Not a `Timer`: a main-thread `Timer` needs a run loop mode that keeps firing
    /// while this object is being torn down, and cancelling one from `deinit` is the
    /// same class of problem documented on `MenuWidthProbe.watch` below. `deinit` on
    /// a `@MainActor` class is `nonisolated`, so it may only touch stored properties
    /// that are themselves `Sendable`. `Task<Void, Never>` is `Sendable`; a
    /// `Timer`, and even more clearly an `NSObjectProtocol` observer token, is not.
    /// `MenuWidthProbe.watch` already hit exactly this: an early version of that
    /// file held an observer token and could not legally release it from `deinit`
    /// under Swift 6, and the fix was switching to a cancellable `Task`. This
    /// property exists so `Store` never makes that same mistake for its own
    /// debounce.
    private var saveTask: Task<Void, Never>?

    init() {
        var loaded = Config.load()
        let removed = loaded.pruneUnavailableApps(isAvailable: Self.appIsAvailable)
        config = loaded
        undoProfileID = nil
        for bundleID in removed { BarHomes.forget(bundleID) }
        if !removed.isEmpty { try? loaded.save() }
    }

    /// Hermetic seam for tests and previews: a fixture config, no disk read and no
    /// first-run default write. Matches `MonitorStore.init(fixtureConfig:)` in
    /// AuthBar, which documents the same rationale. Production code always uses
    /// `init()`.
    init(fixtureConfig: Config) {
        config = fixtureConfig
        undoProfileID = nil
    }

    deinit {
        // Legal precisely because `saveTask` is a `Task`, not an observer token or a
        // `Timer`; see the property's own doc comment for why that swap was
        // necessary rather than stylistic. Cancelling here means a `Store` that is
        // deallocated mid-debounce (window closed a beat after the last edit) never
        // writes a save from a task outliving the object that scheduled it.
        saveTask?.cancel()
    }

    /// Cancels any pending write and schedules a new one `saveDebounce` out. Rapid
    /// edits (a stepper drag, several toggles in a row) collapse into the single
    /// write that lands after the user stops touching the controls, rather than one
    /// write per intermediate value.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = config
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            try? snapshot.save()
            self?.saveTask = nil
        }
    }

    // MARK: - Convenience accessors
    //
    // Forward to Config's own resolved values so a view holding a Store never has
    // to reach past it into `config.foo ?? default` at the call site.

    var revealOnHoverEnabled: Bool { config.revealOnHoverEnabled }
    var autoTuckDelay: TimeInterval { config.autoTuckDelay }
    var launchAtLoginEnabled: Bool { config.launchAtLoginEnabled }
    var spacerRestingLengthPoints: Double { config.spacerRestingLengthPoints }
    var spacerAutosaveNameResolved: String { config.spacerAutosaveNameResolved }
    var profiles: [Config.Profile] { config.profileList }
    var rules: [Config.Rule] { config.ruleList }
    var activeProfile: Config.Profile? { config.activeProfile }

    /// Removes identifiers whose applications no longer exist.
    ///
    /// Called at launch and whenever Arrange refreshes. Installed-but-quit apps remain;
    /// only an identifier absent from both Running Applications and Launch Services is stale.
    @discardableResult
    func pruneUnavailableApps() -> [String] {
        var updated = config
        let known = Set(updated.zoneByBundleID?.keys ?? [:].keys)
            .union(BarHomes.all.keys)
        let removed = known.filter { !Self.appIsAvailable($0) }.sorted()
        guard !removed.isEmpty else { return [] }
        _ = updated.pruneUnavailableApps(isAvailable: Self.appIsAvailable)
        for bundleID in removed { BarHomes.forget(bundleID) }
        config = updated
        return removed
    }

    private static func appIsAvailable(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: - Profiles

    /// Seeds legacy profiles from the current arrangement once.
    ///
    /// The current arrangement becomes Presenting. Screen Share and Focus reveal the one and
    /// three tucked apps nearest the boundary; Everything reveals the full tucked run. Persisting
    /// the generated maps makes every later switch exact rather than recalculating against a bar
    /// whose apps may have moved.
    @discardableResult
    func ensureProfileLayouts(candidateOrder: [String]) -> [Config.Profile] {
        guard !candidateOrder.isEmpty else { return profiles }
        let baseZones = Dictionary(uniqueKeysWithValues: candidateOrder.map {
            ($0, config.zone(forBundleID: $0))
        })
        let renamed = profiles.map { existing -> Config.Profile in
            var profile = existing
            if profile.id == "presenting", profile.name == "Presenting" {
                profile.name = "Default"
            }
            return profile
        }
        let seeded = Self.seededProfiles(
            profiles: renamed,
            baseZones: baseZones,
            candidateOrder: candidateOrder)
        var updated = config
        updated.profiles = seeded
        if updated.activeProfileID == nil {
            updated.activeProfileID = seeded.first?.id
        }
        if updated != config { config = updated }
        return seeded
    }

    nonisolated static func seededProfiles(
        profiles: [Config.Profile],
        baseZones: [String: Zone],
        candidateOrder: [String]
    ) -> [Config.Profile] {
        let tucked = candidateOrder.filter { baseZones[$0] == .tucked }
        return profiles.map { existing in
            guard existing.appZones == nil else { return existing }
            var profile = existing
            var zones = baseZones
            let revealCount = existing.tuckedRunDepth == Int.max
                ? tucked.count
                : min(max(0, existing.tuckedRunDepth), tucked.count)
            for bundleID in tucked.suffix(revealCount) {
                zones[bundleID] = .pinned
            }
            profile.appZones = zones
            return profile
        }
    }

    /// Activates a saved profile and returns the complete configuration the arranger must apply.
    @discardableResult
    func apply(_ requested: Config.Profile,
               candidateOrder: [String],
               recordUndo: Bool = true) -> Config {
        let seeded = ensureProfileLayouts(candidateOrder: candidateOrder)
        guard let profile = seeded.first(where: { $0.id == requested.id }) else { return config }
        var updated = config
        if recordUndo, updated.activeProfileID != profile.id {
            undoProfileID = updated.activeProfileID
        }
        updated.activeProfileID = profile.id
        updated.spacerRestingLength = profile.spacerLength
        if let profileZones = profile.appZones {
            var zones = updated.zoneByBundleID ?? [:]
            for (bundleID, zone) in profileZones { zones[bundleID] = zone }
            updated.zoneByBundleID = zones
        }
        config = updated
        return updated
    }

    @discardableResult
    func undoProfile(candidateOrder: [String]) -> Config? {
        guard let undoProfileID,
              let profile = profiles.first(where: { $0.id == undoProfileID }) else { return nil }
        self.undoProfileID = nil
        return apply(profile, candidateOrder: candidateOrder, recordUndo: false)
    }

    func restoreProfileState(config: Config, undoProfileID: String?) {
        self.config = config
        self.undoProfileID = undoProfileID
    }

    /// Changes one zone and records it in the active profile's snapshot.
    func setZone(_ zone: Zone, forBundleID bundleID: String) {
        var updated = config
        updated.setZone(zone, forBundleID: bundleID)
        if let activeID = updated.activeProfileID,
           var profiles = updated.profiles,
           let index = profiles.firstIndex(where: { $0.id == activeID }) {
            var zones = profiles[index].appZones ?? (updated.zoneByBundleID ?? [:])
            zones[bundleID] = zone
            profiles[index].appZones = zones
            updated.profiles = profiles
        }
        config = updated
    }

    static let builtInProfileIDs: Set<String> = [
        "presenting", "screen-share", "focus", "everything",
    ]

    @discardableResult
    func createProfile(name: String, candidateOrder: [String]) -> Config.Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "New Profile" : trimmed
        let zones = Dictionary(uniqueKeysWithValues: candidateOrder.map {
            ($0, config.zone(forBundleID: $0))
        })
        let profile = Config.Profile(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: resolvedName,
            spacerLength: config.spacerRestingLengthPoints,
            tuckedRunDepth: zones.values.filter { $0 == .pinned }.count,
            hotkeyDisplay: "",
            appZones: zones)
        var updated = config
        var profiles = updated.profileList
        profiles.append(profile)
        updated.profiles = profiles
        updated.activeProfileID = profile.id
        config = updated
        return profile
    }

    func renameProfile(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = config
        var profiles = updated.profileList
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        updated.profiles = profiles
        config = updated
    }

    @discardableResult
    func duplicateProfile(id: String) -> Config.Profile? {
        var updated = config
        var profiles = updated.profileList
        guard var copy = profiles.first(where: { $0.id == id }) else { return nil }
        copy.id = "custom-\(UUID().uuidString.lowercased())"
        copy.name += " Copy"
        copy.hotkeyDisplay = ""
        profiles.append(copy)
        updated.profiles = profiles
        updated.activeProfileID = copy.id
        config = updated
        return copy
    }

    @discardableResult
    func deleteProfile(id: String) -> String? {
        guard !Self.builtInProfileIDs.contains(id) else { return config.activeProfileID }
        var updated = config
        var profiles = updated.profileList
        guard profiles.contains(where: { $0.id == id }) else { return updated.activeProfileID }
        profiles.removeAll { $0.id == id }
        updated.profiles = profiles
        if updated.activeProfileID == id {
            updated.activeProfileID = profiles.first?.id
        }
        config = updated
        return updated.activeProfileID
    }

    func saveCurrentLayout(profileID: String, candidateOrder: [String]) {
        var updated = config
        var profiles = updated.profileList
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].appZones = Dictionary(uniqueKeysWithValues: candidateOrder.map {
            ($0, updated.zone(forBundleID: $0))
        })
        profiles[index].spacerLength = updated.spacerRestingLengthPoints
        updated.profiles = profiles
        config = updated
    }

    // MARK: - Rules
    //
    // Persist and expose only. There is no rules engine in this batch to evaluate
    // a Rule's condition against anything live, matching RulesContentView's own
    // "illustrative, not a builder" framing; adding evaluation here would be
    // building ahead of the surface that is supposed to drive it.

    func addRule(_ rule: Config.Rule) {
        var current = config.ruleList
        current.append(rule)
        config.rules = current
    }

    func removeRule(id: String) {
        config.rules = config.ruleList.filter { $0.id != id }
    }

    func setRule(id: String, isEnabled: Bool) {
        var current = config.ruleList
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].isEnabled = isEnabled
        config.rules = current
    }

    func moveRule(id: String, by offset: Int) {
        guard offset != 0 else { return }
        var current = config.ruleList
        guard let from = current.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), current.count - 1)
        guard to != from else { return }
        let rule = current.remove(at: from)
        current.insert(rule, at: to)
        config.rules = current
    }

    nonisolated static func conflictingRuleIDs(in rules: [Config.Rule]) -> Set<String> {
        var idsByBundle: [String: [String]] = [:]
        for rule in rules where rule.isEnabled {
            guard case .frontmostAppIs(let bundleID) = rule.condition else { continue }
            idsByBundle[bundleID, default: []].append(rule.id)
        }
        return Set(idsByBundle.values.filter { $0.count > 1 }.flatMap { $0 })
    }
}
