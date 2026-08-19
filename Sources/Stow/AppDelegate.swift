import AppKit
import SwiftUI

/// Handles the one AppKit lifecycle event SwiftUI does not expose: reopen.
///
/// Stow is an `LSUIElement` app, so it has no Dock icon, but double-clicking it in
/// Finder or running `open -a Stow` a second time still sends a reopen event. With no
/// handler, nothing happened at all, which left the window reachable only through the
/// menu bar item. Every other Mac app opens something when you launch it twice.
///
/// The delegate posts rather than opening the window itself, because `openWindow` is a
/// SwiftUI environment value that only exists inside a scene. The scene observes this
/// notification and does the opening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Posted when the user launches Stow while it is already running.
    static let reopenRequested = Notification.Name("dev.starkpat.stow.reopenRequested")

    /// Drops the memoised menu bar heights when the display configuration changes.
    ///
    /// `BarScanner` caches the Window Server's measured bar height per display, because measuring
    /// it is a second full window-list walk and it was costing 36% of the hottest primitive in the
    /// app. That cache is only safe with an invalidation, and this is it: plugging in a display,
    /// unplugging one, or changing a resolution all arrive here.
    ///
    /// The cache is also keyed on screen frame, so a resolution change would miss rather than
    /// return a stale value even without this. Both together, because a miss re-measures one screen
    /// while this clears every screen, and a display change can reshape more than the one that
    /// changed.
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        BarScanner.forgetMeasuredBarHeights()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Raise here, DIRECTLY, as well as posting.
        //
        // The notification alone did not work: it is observed on the menu bar label, and a
        // `MenuBarExtra` label does not receive it reliably. Measured, with Finder frontmost and
        // Stow relaunched: the frontmost app stayed Finder even though Stow's window existed.
        // This delegate method definitely runs, so the raising happens here and the notification
        // remains only to CREATE the window when there is not one yet.
        Self.bringWindowForward()
        NotificationCenter.default.post(name: Self.reopenRequested, object: nil)
        // False: AppKit must not try to unminiaturise or front a window itself. The scene owns
        // the window's lifetime, and letting AppKit act as well raced it into fronting a window
        // that had not been created yet.
        return false
    }

    /// Brings Stow's window to the front, switching activation policy to make that possible.
    ///
    /// `NSApp.activate` is REFUSED for an `.accessory` application, and that refusal is the whole
    /// bug: measured twice, with Finder frontmost and Stow asked to show its window, the
    /// frontmost app stayed Finder and the window opened buried. macOS will not hand activation
    /// to an app that has declared it has no place in the Dock.
    ///
    /// So the policy is borrowed. Stow becomes `.regular` while its window is open, which is what
    /// lets it come forward like any other app, and reverts to `.accessory` when the window
    /// closes so it goes back to being a menu bar tool with no Dock icon.
    static func bringWindowForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Identify the window by its SwiftUI identifier rather than by title or by taking the
        // first one: `keyWindow` is nil for a non-active app, and Stow also owns the panel's own
        // window, which must not be raised in its place.
        let target = NSApp.windows.first {
            $0.identifier?.rawValue.contains(MainWindow.windowID) == true
        } ?? NSApp.windows.first { $0.title == "Stow" && $0.isVisible }
        target?.makeKeyAndOrderFront(nil)
        watchForClose(of: target)
    }

    /// Reverts to `.accessory` when the window closes.
    ///
    /// Stow is switched to `.regular` in order to come to the front, because macOS refuses to
    /// activate an `.accessory` app: with Finder frontmost, activation was measured doing
    /// nothing at all. But `.regular` gives Stow a Dock icon and a full menu bar of its own,
    /// which is wrong for a menu bar tool once its window is gone. So the policy is borrowed,
    /// not adopted.
    ///
    /// One observer per window, torn down as it fires, so repeatedly opening and closing does
    /// not accumulate them.
    ///
    /// Removed by OBJECT rather than by holding the returned token. Capturing a mutable token
    /// inside the very closure that assigns it is not concurrency-safe and Swift 6 says so;
    /// `removeObserver(_:name:object:)` needs neither the token nor the mutation.
    static func watchForClose(of window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
                guard let closing = note.object as? NSWindow else { return }
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.willCloseNotification, object: closing)
                // A turn of the loop first: reverting while the window is still tearing down
                // leaves the app briefly with no policy matching its state, and AppKit reacts by
                // flashing a Dock icon.
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
    }
}
