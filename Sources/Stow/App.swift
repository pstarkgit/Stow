import SwiftUI
import AppKit

@main
struct StowApp: App {

    /// Live measurements behind both the panel and the bar glyph.
    @StateObject private var snapshot = BarSnapshot()
    /// Owned here rather than by the panel, because `WhatsNewPane` reads it from
    /// the environment in the WINDOW scene and the panel offers the update in the
    /// MENU BAR scene. One instance has to outlive both, so it lives at the top.
    @StateObject private var updater = Updater()
    /// The persisted policy layer: reveal behaviour, spacer geometry, named
    /// profiles, and rules. Owned here, same as `updater`, so the Settings,
    /// Profiles, and Rules destinations in the window scene and any future
    /// consumer in the menu bar scene all read and write the SAME instance.
    @StateObject private var store = Store()
    /// Owns the seam and the hide/reveal action, which is the app's whole purpose.
    /// Top-level like `updater` and `store`, because the Doctor reads the seam's
    /// measured width in the WINDOW scene while the panel drives it from the MENU BAR
    /// scene, and both must see the same seam.
    @StateObject private var hider = HideController()
    @StateObject private var ruleEngine = RuleEngine()
    /// Owns the temporary reveal-then-retuck for one tucked item at a time, driven by
    /// `onOpenHidden` below.
    ///
    /// The shared coordinator, NOT a `@StateObject`.
    ///
    /// It owns a re-tuck timer that must outlive any view rebuild, and SwiftUI was measured
    /// destroying a `@StateObject` here mid-launch. `RevealCoordinator.shared` explains the
    /// ownership in full.
    private var revealer: RevealCoordinator { .shared }

    /// Which sidebar destination the window shows. Held here so the panel's icon
    /// row can aim it: gear to Settings, flask to Doctor.
    @State private var destination: MainWindow.Destination = .arrange

    @Environment(\.openWindow) private var openWindow

    /// Opens the window when the app is "launched" again while already running.
    ///
    /// An `LSUIElement` app has no Dock icon, but double-clicking it in Finder, or a
    /// second `open -a Stow`, still sends a reopen event. Without a handler nothing
    /// happens at all, so Stow's window was reachable ONLY through its menu bar item.
    /// That is wrong on its own terms: every other Mac app opens something when you
    /// launch it twice.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // CLI modes run and exit BEFORE any UI state is constructed.
        //
        // `--probe` is the project's hard gate and must be runnable without the rest
        // of the app existing. Same pattern as `AuthBar --check`, and the same
        // ordering discipline: nothing that touches a user-facing subsystem may be
        // created above this guard, or a bare `.build/release/Stow --probe` would
        // trip on it.
        let args = CommandLine.arguments
        if args.contains("--probe") {
            MainActor.assumeIsolated { Probe.runAndExit() }
        }
        if args.contains("--seam") {
            MainActor.assumeIsolated { SpacerItem.runSeamAndExit() }
        }
        if args.contains("--panel") {
            MainActor.assumeIsolated { StatusPanel.runPanelAndExit() }
        }
        if args.contains("--move") {
            MainActor.assumeIsolated { ItemMover.runMoveAndExit() }
        }
        if args.contains("--rows") {
            MainActor.assumeIsolated { BarSnapshot.runRowsAndExit() }
        }
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let needle = args[i + 1]
            MainActor.assumeIsolated { BarSnapshot.runOpenAndExit(matching: needle) }
        }
        if args.contains("--hide") {
            MainActor.assumeIsolated { SpacerItem.runHideAndExit() }
        }
        if args.contains("--version") {
            print(StowVersion.display)
            exit(0)
        }

        // Place Stow's own token OUTSIDE the seam, before the token exists.
        //
        // This must happen in `init`, above the scene body, because AppKit reads the
        // placement preference when the status item is created and `MenuBarExtra`
        // creates its item as soon as the body is first evaluated. Writing it later
        // would only take effect on the next launch.
        //
        // Not cosmetic. The first verified `--hide` run pushed Stow's own token off
        // the bar along with the eight items it was asked to hide, which left no
        // control anywhere to bring them back.
        SpacerItem.migrateLegacyPlacementsIfNeeded()
        HideController.placeOwnTokenOutsideSeam()

        // AppKit may terminate an "inactive" LSUIElement app via Automatic
        // Termination. Opt out hard: Stow holds the spacer item, and if it is killed
        // the user's tucked items stay off the bar with nothing left to bring them
        // back. That failure is worse than for either sibling.
        ProcessInfo.processInfo.disableAutomaticTermination("menu bar manager")
    }

    var body: some Scene {
        MenuBarExtra {
            LiveStatusPanel(
                // THE action. Toggling the seams is what Stow is for, and it is wired to the
                // panel's one primary control.
                onTuckAllButPinned: {
                    hider.toggle()
                    // Keep the shared snapshot current for the glyph and diagnostics.
                    remeasure()
                },
                // Clicking a hidden app opens its menu WITHOUT un-hiding it. Verified on a real
                // hidden item at x-3036: pressed through accessibility, its menu opened.
                onOpenHidden: { app in
                    // Dismiss Stow's own panel first. Two menu sessions cannot be open at once,
                    // so the target's menu would otherwise fight the one this click arrived
                    // through.
                    NSApp.sendAction(#selector(NSMenu.cancelTracking), to: nil, from: nil)
                    let pid = app.pid

                    // Bring the item back to the visible bar BEFORE pressing it. Pressing while
                    // it stays off-screen at a large negative x is the bug being fixed here: the
                    // menu opened, but the item itself was neither visible nor usable, verified
                    // directly against a real hidden item that reported x-3036.
                    //
                    // Falls back to pressing where it stands on ANY failure, seam missing or the
                    // move itself refused: a menu at a negative x is worse than a visible one but
                    // far better than a dead click, which is what doing nothing here would be.
                    do {
                        try revealer.reveal(bundleID: app.bundleID, pid: pid,
                                            seamWindow: hider.tuckedSeamWindow,
                                            duration: store.config.revealDuration)
                    } catch {
                        // Never press an item whose reveal failed. ACME reports AX x=-1 while
                        // tucked; pressing that sentinel opens its menu at the far-left edge.
                        // When macOS has removed the status-item window entirely, use the app's
                        // ordinary reopen path instead. Verified with ACME: this opens its real
                        // Overview window at a normal screen position rather than the left-edge
                        // fallback menu. Normal hidden items still take the menu reveal path.
                        guard let url = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: app.bundleID) else { return }
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: url,
                                                           configuration: configuration) { _, _ in }
                        return
                    }

                    // Detached, NOT a main-actor Task. The press blocks for up to about 1.76s
                    // waiting on a reply the target never sends, since the menu it opened is
                    // modal. On the main actor that is a frozen panel for an action the user
                    // already saw succeed.
                    Task.detached {
                        // Let the panel's own menu session finish, then wait for AX to catch up
                        // with the WindowServer move. A fixed delay left ACME at x=-1 and caused
                        // macOS to clamp its menu to the far-left edge.
                        guard PressActionProbe.waitForVisiblePressItem(pid: pid) else { return }
                        _ = PressActionProbe.press(pid: pid)
                    }
                },
                onUpdate: { updater.update() },
                onArrange: { open(.arrange) },
                onDiagnostics: { open(.doctor) },
                onSettings: { open(.settings) },
                onQuit: { NSApp.terminate(nil) },
                onApplyProfile: { profileID in
                    guard let profile = store.profiles.first(where: { $0.id == profileID })
                    else { return }
                    ruleEngine.noteManualSelection(selectedProfileID: profile.id)
                    _ = activateProfile(profile)
                },
                onUndoProfile: {
                    ruleEngine.noteManualSelection(selectedProfileID: store.undoProfileID)
                    undoProfile()
                })
                // MenuBarExtra content is hosted separately from the label task. Passing scalar
                // copies of presentation and failures here left the compact panel frozen at its
                // launch snapshot while the Arrange window correctly observed the live hider.
                // The host below reads every panel-facing model as an EnvironmentObject, so the
                // launch restore and later lifecycle checks redraw this exact surface.
                .environmentObject(snapshot)
                .environmentObject(updater)
                .environmentObject(store)
                .environmentObject(hider)
                .environmentObject(ruleEngine)
                // Re-measure every time the panel opens: the window server and the
                // frontmost app both move under us while the panel is closed, so a
                // value captured at launch would be stale by the first open.
                //
                // The seam is NOT created here. It is created on the menu bar label
                // instead, which SwiftUI builds eagerly at scene creation while this
                // content view is built lazily on first open. Creating it here meant a
                // fresh install had no seam, and no placement preference, until the user
                // happened to click the icon.
                .task { remeasure() }
        } label: {
            // Image(nsImage:) keeps the explicit gradient. An SF Symbol via
            // Image(systemName:) would be templated to monochrome and every stop
            // in StowGlyph.paint would be discarded.
            //
            // Setup lives on the LABEL, not the content: MenuBarExtra builds the
            // label eagerly at scene creation but the content view lazily on first
            // open, so a .task on the content would leave hotkeys unregistered
            // until the user first clicked. Learned from AuthBar's App.swift.
            Image(nsImage: StowGlyph.image(for: snapshot.state))
                .task {
                    EmergencyHotKey.shared.register {
                        hider.showEverything()
                        remeasure()
                    }
                    store.pruneUnavailableApps()
                    let candidateOrder = hider.currentCandidates(config: store.config).map(\.bundleID)
                    store.ensureProfileLayouts(candidateOrder: candidateOrder)
                    ProfileHotKeys.shared.register(profiles: store.profiles) { profile in
                        ruleEngine.noteManualSelection(selectedProfileID: profile.id)
                        _ = activateProfile(profile)
                    }
                    if let activeProfile = store.activeProfile {
                        _ = store.apply(activeProfile, candidateOrder: candidateOrder)
                    }
                    // Create the seam at LAUNCH, not on first panel open.
                    //
                    // Its placement is read from a preference at creation time, so
                    // creating it here is what lets Stow place itself before the user
                    // touches anything. On the content view it only ran when the panel
                    // was first opened, which left the placement preference unwritten
                    // and, worse, made an item appear at the moment the user asked for
                    // items to disappear.
                    // Restore the user's saved choices, not merely the seam's placement.
                    // Without this a relaunch silently un-hides everything and every
                    // unchecked box in Arrange becomes a lie until Apply is pressed again.
                    //
                    // Restored by MOVING APPS around the seam, the same way a drag does, so the
                    // bar a relaunch produces is the bar a drag produces. Wiring only the drag
                    // path would have left every launch showing swept-off neighbours until the
                    // user happened to drag something, which is a worse bug than the one it
                    // replaced because it looks like Stow forgot the configuration.
                    //
                    // Legacy Deep Storage assignments resolve to In Stow. Always use the
                    // stationary one-hatch arranger; the old two-hatch path could sweep apps
                    // the user never selected.
                    hider.restoreSavedLayout(from: store.config)
                    remeasure()
                    ruleEngine.start(
                        rules: { store.rules },
                        activeProfileID: { store.activeProfile?.id },
                        applyProfile: { profileID in
                            guard let profile = store.profiles.first(where: { $0.id == profileID })
                            else { return false }
                            return activateProfile(profile, intent: .background)
                        },
                        profileName: { profileID in
                            store.profiles.first(where: { $0.id == profileID })?.name ?? profileID
                        })

                    // Quiet check at launch, then every six hours, matching
                    // AuthBar. On the label so it starts without waiting for the
                    // user's first click on the icon.
                    await updater.check(quiet: true)
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(6 * 3600))
                        await updater.check(quiet: true)
                    }
                }
                // Reconcile the already-selected layout after app lifecycle changes. Two bounded
                // passes catch menu items created after NSWorkspace's process notification. Each
                // pass first proves the layout is already correct and moves nothing in that common
                // case; only real saved-layout drift invokes the cursor-restoring arranger.
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didLaunchApplicationNotification)) { _ in
                        Task { @MainActor in
                            for delay in [500, 1_000] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                hider.refreshCandidatesWithoutMoving()
                                hider.reconcileSavedLayoutAfterCandidateChange(from: store.config)
                                remeasure()
                            }
                        }
                    }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didTerminateApplicationNotification)) { _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(500))
                            hider.refreshCandidatesWithoutMoving()
                            hider.reconcileSavedLayoutAfterCandidateChange(from: store.config)
                            remeasure()
                        }
                    }
                // Launching Stow again while it is already running opens the window.
                // On the LABEL because that view lives for the whole session: on the
                // window's own content it would only be listening while the window was
                // already open, which is exactly when nobody needs it.
                .onReceive(NotificationCenter.default.publisher(
                    for: AppDelegate.reopenRequested)) { _ in
                        open(.arrange)
                    }
        }
        .menuBarExtraStyle(.window)

        // ONE window with a sidebar, per design section 10. The id MUST stay
        // "settings": every `openWindow(id:)` call site targets it through
        // `MainWindow.windowID`, and the design is explicit that keeping the
        // string is what let AuthBar collapse two windows into one without
        // touching any caller.
        Window("Stow", id: MainWindow.windowID) {
            MainWindow(destination: $destination)
                .environmentObject(updater)
                .environmentObject(store)
                // The Arrange pane reads and MOVES the cut, so it needs the same
                // controller the panel's pill drives. One instance, both scenes: two
                // would each own a seam and contend over the bar's layout, which is
                // the exact failure mode two competing managers produce.
                .environmentObject(hider)
                .environmentObject(ruleEngine)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }

    /// Re-measures the bar, telling the snapshot which items are Stow's own seams first.
    ///
    /// Every refresh goes through here rather than calling `snapshot.refresh()` directly, so
    /// the seam identities cannot be forgotten at one call site and remembered at another.
    /// That is exactly how the panel came to print impossible arithmetic ("5510 in use" on a
    /// 2560pt bar) while the Arrange pane, which excluded the seams, printed the truth.
    ///
    /// The numbers are asked of the `HideController` each time because a seam's window number
    /// changes whenever it is repositioned: `reposition` destroys and recreates the item, so a
    /// set cached once would go stale on the first drag.
    @MainActor
    private func remeasure() {
        snapshot.seamWindows = hider.seamWindowNumbers()
        snapshot.refresh()
    }

    private enum ProfileActivationIntent {
        case explicitUserAction
        case background
    }

    /// Applies a profile from the UI, a shortcut, or a classified background rule.
    @discardableResult
    private func activateProfile(
        _ profile: Config.Profile,
        intent: ProfileActivationIntent = .explicitUserAction
    ) -> Bool {
        let candidateOrder = hider.currentCandidates(config: store.config).map(\.bundleID)
        let previous = store.config
        let previousUndo = store.undoProfileID
        let profileConfig = store.apply(profile, candidateOrder: candidateOrder)
        let arrangementIntent: HideController.ArrangementIntent = intent == .explicitUserAction
            ? .explicitUserAction : .background
        let outcome = hider.arrangeByMovingItems(
            from: profileConfig,
            intent: arrangementIntent)
        if !outcome.isClean {
            store.restoreProfileState(config: previous, undoProfileID: previousUndo)
        }
        remeasure()
        return outcome.isClean
    }

    private func undoProfile() {
        let candidateOrder = hider.currentCandidates(config: store.config).map(\.bundleID)
        let previous = store.config
        let previousUndo = store.undoProfileID
        guard let undoConfig = store.undoProfile(candidateOrder: candidateOrder) else { return }
        let outcome = hider.arrangeByMovingItems(
            from: undoConfig,
            intent: .explicitUserAction)
        if !outcome.isClean {
            store.restoreProfileState(config: previous, undoProfileID: previousUndo)
        }
        remeasure()
    }

    /// Opens the window on a specific destination, and brings it to the FRONT.
    ///
    /// Routes through `WindowTarget` rather than assigning `destination` directly, because the
    /// panel and the window are separate scenes: setting the binding from here would not
    /// survive the window being closed and reopened, which is the case `WindowTarget` exists
    /// to carry.
    ///
    /// The activation is the part that was missing, and it is not optional for this app. Stow
    /// is `LSUIElement`, so it has no Dock icon and is never the active application;
    /// `openWindow` creates the window but nothing raises it, so pressing the gear in the
    /// panel opened Settings BEHIND whatever the user was already looking at. Reported as
    /// exactly that: "why is it not bringing that window to the front, its buried."
    ///
    /// Activating is not enough on its own, and this is the part that actually failed.
    /// `NSApp.activate` is REFUSED for an `.accessory` application: measured, with Finder
    /// frontmost and Stow asked to open its window, the frontmost app stayed Finder and Stow's
    /// window opened behind it. macOS will not hand activation to an app that has declared it
    /// has no place in the Dock.
    ///
    /// So the policy changes first. Stow becomes `.regular` for as long as its window is open,
    /// which is what lets it come to the front like any other app, and reverts to `.accessory`
    /// when the window closes so it goes back to being a menu bar tool with no Dock icon.
    ///
    /// Deferred by one turn of the main queue rather than called inline: `openWindow` creates
    /// the window asynchronously, so on the first press there is no window to raise yet, and
    /// raising before it exists silently does nothing.
    private func open(_ dest: MainWindow.Destination) {
        MainWindow.WindowTarget.shared.request(dest)
        openWindow(id: MainWindow.windowID)

        DispatchQueue.main.async {
            // One implementation, shared with the reopen path. It was duplicated for a moment and
            // that is exactly how two paths drift into behaving differently.
            AppDelegate.bringWindowForward()
        }
    }
}

/// Bridges the separately hosted MenuBarExtra content to the live shared models.
///
/// Keep this as an observing view rather than passing panel values from `StowApp.body`.
/// SwiftUI can retain a menu-extra content closure independently of the label task that performs
/// launch restoration. Scalar arguments then remain the values from the first construction even
/// though the underlying controller changes. EnvironmentObject reads establish subscriptions in
/// the hosted content itself, so the compact panel and the main window always render one state.
@MainActor
private struct LiveStatusPanel: View {
    @EnvironmentObject private var snapshot: BarSnapshot
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var hider: HideController
    @EnvironmentObject private var ruleEngine: RuleEngine

    var onTuckAllButPinned: () -> Void
    var onOpenHidden: (HiddenApp) -> Void
    var onUpdate: () -> Void
    var onArrange: () -> Void
    var onDiagnostics: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void
    var onApplyProfile: (String) -> Void
    var onUndoProfile: () -> Void

    var body: some View {
        StatusPanel(
            state: snapshot.state,
            // Hidden apps come from persisted zones because pushed-off items are absent from the
            // visible scan by definition.
            hiddenApps: hider.hiddenApps(from: store.config),
            arrangementFailures: hider.lastArrangeFailures
                + hider.pinnedAvailabilityFailures(from: store.config),
            onTuckAllButPinned: onTuckAllButPinned,
            presentation: hider.presentation,
            onOpenHidden: onOpenHidden,
            onUpdate: onUpdate,
            onArrange: onArrange,
            onDiagnostics: onDiagnostics,
            onSettings: onSettings,
            onQuit: onQuit,
            updateAvailable: {
                switch updater.state {
                case .available, .restartRequired: return true
                default: return false
                }
            }(),
            profiles: store.profiles,
            activeProfileID: store.activeProfile?.id,
            canUndoProfile: store.undoProfileID != nil,
            onApplyProfile: onApplyProfile,
            onUndoProfile: onUndoProfile,
            automationReason: ruleEngine.activeRuleID == nil
                ? nil : ruleEngine.activeReason)
    }
}
