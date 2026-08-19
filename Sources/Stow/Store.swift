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
/// What genuinely remains unwired: `apply(_ profile:)` persists `activeProfileID` and nothing else,
/// and there is no rules engine reading `Config.rules`.
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
        config = Config.load()
    }

    /// Hermetic seam for tests and previews: a fixture config, no disk read and no
    /// first-run default write. Matches `MonitorStore.init(fixtureConfig:)` in
    /// AuthBar, which documents the same rationale. Production code always uses
    /// `init()`.
    init(fixtureConfig: Config) {
        config = fixtureConfig
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

    // MARK: - Profiles

    /// Records `profile` as active and publishes the change.
    ///
    /// This does NOT move a single status item, and it must not grow to: the
    /// mechanism that would move one is a reveal engine that PLAN A builds later
    /// and does not exist yet in this batch. What this method CAN do honestly is
    /// remember the user's choice, so the Profiles pane can say "selection
    /// persists" rather than lying about a spacer or reveal it never touches.
    /// Once that engine lands, it is the one that reads `activeProfile` and acts
    /// on `spacerLength`/`tuckedRunDepth`; this method's job stops at persisting
    /// the choice.
    func apply(_ profile: Config.Profile) {
        config.activeProfileID = profile.id
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
}
