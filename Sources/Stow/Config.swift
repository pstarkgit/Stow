import Foundation

/// User configuration, stored at ~/.config/stow/config.json.
///
/// Same family convention as the sibling menu bar apps, with the same `load`/`save`
/// shape and reasoning: a menu bar app has to keep launching even
/// when its own config file is missing or damaged, so every failure path here degrades
/// to `.default` rather than throwing out of `init`.
///
/// CORRECTED: this file's header used to claim there is no stable per-app identity for
/// a third-party status item on this OS, and that nothing here may persist a value
/// keyed to "which app owns this item". That claim was wrong, and the mistake was
/// asking the wrong process. Two facts behind it are still true and still matter:
/// `kCGWindowOwnerPID` really does resolve to the Control Center process for every
/// status item, Stow's own included, and `kCGWindowName` really is the literal string
/// `Item-0` for every third-party one. Those two facts are exactly why a window number
/// or `ObservedItem.ownerPID` must NEVER be the persisted key: both name the process
/// hosting the item, not the app that owns it, and a window number does not even
/// survive the owning app's next relaunch. But Control Center only HOSTS the items; it
/// does not own them. Each owning application still answers for its own status items,
/// and `BarItemOwners.claims()` asks every running app for its own `AXExtrasMenuBar`
/// rather than asking the window server, which is what recovers a real `bundleID`. A
/// bundle id names the app, not a window or a process id that dies with it, so it
/// survives a relaunch and is a legitimate persisted key. `zoneByBundleID` below is
/// that key in use. What still does not exist is a reveal engine that ACTS on it:
/// `Profile` stores spacer geometry and reveal behaviour, `Rule.Action` targets an
/// ordinal position or a profile, and moving an item between zones remains later work.
struct Config: Codable, Equatable, Sendable {

    /// One saved arrangement: the spacer geometry and reveal behaviour to apply, plus,
    /// now that bundle id is a stable key (see this file's header comment), an
    /// optional real set of apps. Design section 10 names four: Presenting, Screen
    /// Share, Focus, Everything, each with one hotkey.
    ///
    /// `appZones` is optional, like every other field here, so a config written
    /// before this field existed still decodes with no per-app membership at all.
    /// What a profile always owns regardless is how FAR the spacer opens and how much
    /// of the tucked run stays visible: those numbers describe the SHAPE of the
    /// arrangement whether or not any particular app is named in it.
    struct Profile: Codable, Equatable, Sendable, Identifiable {
        /// Stable across renames, unlike `name`. Never regenerated on decode, so a
        /// hand-edited config keeps pointing `activeProfileID` at the same profile
        /// even after the display name changes.
        var id: String
        var name: String
        /// The spacer's resting length in points while this profile is active. A
        /// larger resting length keeps more of the tucked run permanently off the
        /// bar; applied to the spacer status item on activation, an item PLAN A.1
        /// builds and this batch's `Store` does not depend on per the batch
        /// contract.
        var spacerLength: Double
        /// How many of the tucked items, counted out from the spacer, should stay
        /// reachable from the sub-bar rather than falling all the way to vaulted.
        /// Zero means "hide the whole run"; a large number means "keep everything
        /// one hotkey away." Still a depth, not an app list: which apps currently sit
        /// in the tucked run is `appZones` below (or the default spacer position when
        /// unset); this field only says how deep a reveal should go.
        var tuckedRunDepth: Int
        /// Display form of the hotkey, `"⌘⇧1"`. A plain `String` rather than a
        /// parsed key combo on purpose: a hotkey manager is PLAN A.4 and does not
        /// exist yet, so there is nothing to parse this into today. Rendered as-is
        /// by the Profiles pane.
        var hotkeyDisplay: String
        /// Per-app zone membership this profile applies, keyed by bundle id. `nil`
        /// means this profile does not decide any app's zone; an app absent from a
        /// non-nil map means the same thing for that one app. Optional so a config
        /// saved before this field existed keeps decoding.
        var appZones: [String: Zone]?

        init(id: String, name: String, spacerLength: Double, tuckedRunDepth: Int,
             hotkeyDisplay: String, appZones: [String: Zone]? = nil) {
            self.id = id
            self.name = name
            self.spacerLength = spacerLength
            self.tuckedRunDepth = tuckedRunDepth
            self.hotkeyDisplay = hotkeyDisplay
            self.appZones = appZones
        }
    }

    /// One auto-apply rule: design section 10's two worked examples are the shape
    /// this supports ("Screen sharing starts, then hide Vendor VPN"; "A meeting app
    /// is frontmost, then reveal Murmur"). There is no rules engine yet to evaluate
    /// these; `Store` persists and exposes them and nothing more, matching
    /// `RulesContentView`'s own "illustrative, not a builder" framing.
    struct Rule: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var isEnabled: Bool
        var condition: Condition
        var action: Action

        init(id: String, isEnabled: Bool, condition: Condition, action: Action) {
            self.id = id
            self.isEnabled = isEnabled
            self.condition = condition
            self.action = action
        }

        /// What triggers the rule. `frontmostAppIs` needs no persisted status-item key
        /// at all: `NSWorkspace.frontmostApplication` is a live, OS-maintained fact
        /// about the ACTIVE app, resolved fresh every time the condition is checked,
        /// not read back out of a config file. What Condition never carries is a
        /// reference to a specific STATUS ITEM by window number, since a window number
        /// is exactly the identity that does NOT survive a relaunch (see this file's
        /// header comment).
        enum Condition: Codable, Equatable, Sendable {
            case screenSharingStarted
            case screenSharingEnded
            case frontmostAppIs(bundleID: String)
        }

        /// What the rule does. Not yet "reveal this app's item": that target resolves
        /// fine now (`BarItemOwners` recovers a real bundle id per item), but there is
        /// no rules engine in this batch to evaluate a Rule against anything live, so
        /// adding a target this type cannot yet act on would be building ahead of the
        /// engine that would carry it out. Both cases below name something the design
        /// can already record: a saved profile, or an ordinal slot counted from the
        /// spacer, which is the same position-based addressing `Zone` itself uses.
        /// This type only has to be able to describe the action, not perform it.
        enum Action: Codable, Equatable, Sendable {
            case applyProfile(id: String)
            /// Reveal the item currently sitting `depth` slots into the tucked
            /// run, counted out from the spacer. NOT a bundle ID: the item at a
            /// given depth today may be a different app after the next relaunch,
            /// and that is fine, because the rule is describing a SLOT, not an
            /// app.
            case revealTuckedSlot(depth: Int)
            /// Tuck the pinned item currently sitting `depth` slots in from the
            /// spacer, for the "hide Vendor VPN" example. Same position-based
            /// addressing as `revealTuckedSlot`, mirrored to the other side of
            /// the spacer.
            case tuckPinnedSlot(depth: Int)
        }
    }

    // MARK: - Fields

    /// Reveal a tucked item on hover, without needing the hotkey or a sub-bar
    /// click. `nil` means "not yet decided"; `revealOnHoverEnabled` resolves it.
    var revealOnHover: Bool?
    /// Seconds an item stays revealed on the stage before auto-tucking back.
    /// `nil` means "use the default"; `autoTuckDelay` resolves it.
    var autoTuckDelaySeconds: Double?
    /// Register `Stow.app` with `SMAppService` at login. `nil` means "not yet
    /// decided"; `launchAtLoginEnabled` resolves it.
    var launchAtLogin: Bool?
    /// The spacer's length at rest, in points, absent an active profile
    /// overriding it. `nil` means "use the design's own 10pt default";
    /// `spacerRestingLengthPoints` resolves it.
    var spacerRestingLength: Double?
    /// `NSStatusItem.autosaveName` for the spacer, so its on-bar position
    /// survives a relaunch the same way every other status item's does. `nil`
    /// means "use the app's own stable default"; `spacerAutosaveNameResolved`
    /// resolves it.
    var spacerAutosaveName: String?
    /// Saved arrangements. `nil`/empty means none exist; `profileList` resolves
    /// it to a concrete array for SwiftUI binding.
    var profiles: [Profile]?
    /// Which profile is active, by `Profile.id`. `nil` means none has been
    /// applied yet.
    var activeProfileID: String?
    /// Auto-apply rules. `nil`/empty means none exist, matching `services` in
    /// AuthBar's own `Config`: the feature is dormant with no rows and nothing
    /// to evaluate, rather than an empty array meaning something different from
    /// an absent key.
    var rules: [Rule]?
    /// Seconds a temporarily-revealed tucked item stays on the visible bar before
    /// `RevealCoordinator` puts it back. `nil` means "use the default";
    /// `revealDuration` resolves it. Separate from `autoTuckDelaySeconds` above: that
    /// field is unused by any caller yet (see this file's header comment), while this
    /// one is read on every `onOpenHidden` click, the temporary-reveal path
    /// `RevealCoordinator` implements.
    var revealDurationSeconds: Double?
    /// Per-app zone membership, keyed by bundle id. `nil` or a missing key means Stow
    /// has not been told to move that app; `zone(forBundleID:)` resolves that silence
    /// to `.pinned`. Bundle id survives a relaunch, unlike a window number or
    /// `ObservedItem.ownerPID` (see this file's header comment), which is what makes
    /// this key legitimate where the header once ruled out any app-keyed persistence
    /// at all.
    var zoneByBundleID: [String: Zone]?

    // MARK: - Defaults

    /// The four profiles design section 10 names, each with one hotkey. Spacer
    /// geometry increases from `presenting` (hide almost everything) through
    /// `everything` (keep the whole run one hotkey away), so the four read as a
    /// real progression rather than four arbitrary names.
    static let defaultProfiles: [Profile] = [
        Profile(id: "presenting", name: "Presenting",
                spacerLength: 10, tuckedRunDepth: 0, hotkeyDisplay: "\u{2318}\u{21E7}1"),
        Profile(id: "screen-share", name: "Screen Share",
                spacerLength: 10, tuckedRunDepth: 1, hotkeyDisplay: "\u{2318}\u{21E7}2"),
        Profile(id: "focus", name: "Focus",
                spacerLength: 10, tuckedRunDepth: 3, hotkeyDisplay: "\u{2318}\u{21E7}3"),
        Profile(id: "everything", name: "Everything",
                spacerLength: 10, tuckedRunDepth: Int.max, hotkeyDisplay: "\u{2318}\u{21E7}4"),
    ]

    static let `default` = Config(
        revealOnHover: true,
        autoTuckDelaySeconds: 4,
        launchAtLogin: false,
        spacerRestingLength: 10,
        spacerAutosaveName: "stow-spacer",
        profiles: defaultProfiles,
        activeProfileID: nil,
        rules: nil
    )

    // MARK: - Convenience accessors
    //
    // Resolve every optional to a concrete value with its default stated once,
    // here, rather than at each call site as a scattered `?? 10` that drifts the
    // moment one call site is updated and the others are not.

    /// Whether hovering a tucked item's tile reveals it without a hotkey or
    /// click. Defaults to true: the seam exists to be discoverable.
    var revealOnHoverEnabled: Bool { revealOnHover ?? true }
    /// Seconds a revealed item stays on the stage before auto-tucking. Clamped
    /// to a minimum of 1: zero or negative would tuck an item before its menu
    /// could ever be reached.
    var autoTuckDelay: TimeInterval { max(1, autoTuckDelaySeconds ?? 4) }
    /// Seconds a temporarily-revealed item stays on the bar before its automatic
    /// re-tuck. Defaults to 15, which is what was asked for. Clamped to a minimum of
    /// 1 for the same reason `autoTuckDelay` is: zero or negative would tuck the item
    /// before the menu `onOpenHidden` opens on it could ever be reached.
    var revealDuration: TimeInterval { max(1, revealDurationSeconds ?? 15) }
    /// Whether Stow is registered to launch at login. Defaults to false: an app
    /// should not opt itself into starting at boot without the user asking.
    var launchAtLoginEnabled: Bool { launchAtLogin ?? false }
    /// The spacer's resting length in points, absent a profile override. Design
    /// section 4 fixes this at 10pt; clamped to a minimum of 1 so a hand-edited
    /// zero or negative value cannot collapse the seam into a zero-width, and
    /// therefore unclickable, click target.
    var spacerRestingLengthPoints: Double { max(1, spacerRestingLength ?? 10) }
    /// The spacer's `NSStatusItem.autosaveName`. A stable non-empty default so
    /// the spacer's on-bar position persists across relaunches even before a
    /// user ever opens Settings.
    var spacerAutosaveNameResolved: String {
        let name = spacerAutosaveName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name! : "stow-spacer"
    }
    /// Non-optional view of `profiles` for SwiftUI binding, matching the
    /// `serviceList` pattern in AuthBar's own `Config`. Falls back to the
    /// design's own four rather than an empty list, so a hand-edited config
    /// that dropped the key still shows the profiles the Profiles pane
    /// promises to have.
    var profileList: [Profile] { (profiles?.isEmpty ?? true) ? Self.defaultProfiles : profiles! }
    /// Non-optional view of `rules` for SwiftUI binding. Empty, not defaulted:
    /// unlike profiles, there is no canonical starting set of rules to fall
    /// back to, only the two illustrative examples `RulesContentView` already
    /// renders as static text.
    var ruleList: [Rule] { rules ?? [] }
    /// The active profile, resolved by `activeProfileID` against `profileList`.
    /// Nil when no profile has been applied yet, or the stored id no longer
    /// matches any profile (a hand-edited config, or one whose profile was
    /// deleted).
    var activeProfile: Profile? {
        guard let id = activeProfileID else { return nil }
        return profileList.first { $0.id == id }
    }

    /// The zone a given app's status item belongs in. Unassigned means `.pinned`: an
    /// item Stow has not been told to move must stay exactly where macOS already put
    /// it, not be swept into `.tucked` or `.vaulted` by a default that looks like an
    /// assignment nobody made.
    func zone(forBundleID bundleID: String) -> Zone {
        let stored = zoneByBundleID?[bundleID] ?? .pinned
        return stored == .vaulted ? .tucked : stored
    }

    /// Whether the zones ask for ANYTHING to be hidden, which decides whether resting the bar is the
    /// honest end state or a lie.
    ///
    /// Lives here because it was written out by hand in two switch statements that must agree: the
    /// arrange's success ending and its failure ending. They were textually identical, and nothing
    /// stopped them drifting. Drift there silently reintroduces a real bug, an arrange that fails and
    /// leaves every tucked app on show, so it is worth one accessor.
    var hidesAnything: Bool {
        (zoneByBundleID ?? [:]).values.contains { $0 != .pinned }
    }

    /// Records `zone` for `bundleID`, creating the map on its first use.
    mutating func setZone(_ zone: Zone, forBundleID bundleID: String) {
        var current = zoneByBundleID ?? [:]
        current[bundleID] = zone == .vaulted ? .tucked : zone
        zoneByBundleID = current
    }

    // MARK: - Persistence

    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/stow/config.json")
    }

    static var legacyAirlockPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/airlock/config.json")
    }

    static func load() -> Config {
        load(primary: path, legacy: legacyAirlockPath)
    }

    /// Loads Stow's config, importing Airlock's file once when this is the first
    /// Stow launch. The legacy file is never modified or removed.
    static func load(primary: URL, legacy: URL?) -> Config {
        if !FileManager.default.fileExists(atPath: primary.path),
           let legacy,
           let data = try? Data(contentsOf: legacy),
           let migrated = try? JSONDecoder().decode(Config.self, from: data) {
            try? migrated.save(to: primary)
            return migrated
        }
        return load(from: primary)
    }

    /// Loads one config path. Mirrors AuthBar's `Config.load(from:)` exactly:
    /// defaults are written ONLY on a genuine first run (the file is absent),
    /// and a file this build cannot decode or read is preserved byte-for-byte
    /// rather than silently replaced. A menu bar app that overwrote a config it
    /// merely failed to parse would risk destroying a file a newer build wrote
    /// and this build does not yet understand.
    ///
    /// `Data(contentsOf:)` throws `fileReadNoSuchFile` (260), not the
    /// `fileNoSuchFile` (4) its name suggests; matching the wrong constant would
    /// send every genuine first run down the preserve branch and never write a
    /// file to edit. AuthBar's own `Config.load(from:)` documents having found
    /// this the hard way; the same constant is used here for the same reason.
    static func load(from url: URL) -> Config {
        do {
            let data = try Data(contentsOf: url)
            guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
                // Present but undecodable: a broken config file must never stop
                // a menu bar app from launching, so fall back to defaults for
                // THIS run without touching the file a future build might still
                // be able to read.
                return Config.default
            }
            return cfg
        } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain
                        && error.code == CocoaError.fileReadNoSuchFile.rawValue {
            let cfg = Config.default
            try? cfg.save(to: url)
            return cfg
        } catch {
            // Present but unreadable for some other reason (permissions, a
            // directory sitting at the path, I/O error). Never write over it.
            return Config.default
        }
    }

    func save() throws {
        try save(to: Config.path)
    }

    /// `internal`, not `private`: `StowTests` needs this to prove the round trip
    /// preserves every field, the same seam AuthBar's own test suite exercises
    /// against its `Config`.
    func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
