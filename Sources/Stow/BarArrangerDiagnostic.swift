import AppKit

extension BarArranger {

    /// `Stow --arrange`: applies the user's real zones by MOVING APPS, and compares the cost
    /// against the seam-moving path on the same bar.
    ///
    /// This is the end-to-end test of a different architecture. Stow ships the seam-moving path:
    /// it searches for a placement slot, costs a measured 5.6s per drop, and cannot go lower
    /// because a reposition is 0.415s and it spends about ten of them. Three attempts to cut
    /// that count all failed their correctness gate.
    ///
    /// The claim under test is that moving APPS around a stationary seam is both cheaper and
    /// more honest: cheaper because only apps on the wrong side cost anything, more honest
    /// because a seam that never moves sweeps nothing by accident, so the two collateral
    /// warnings in the pane have nothing to report.
    ///
    /// Reports BOTH paths so the comparison is measured rather than argued, and verifies the
    /// result against the user's actual zones rather than reporting that it finished.
    static func runArrangeAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - arrange")
        print(String(repeating: "=", count: 68))

        guard Bundle.main.bundleIdentifier != nil else {
            print("  FATAL: no bundle identifier, so Stow cannot tell its own items from the")
            print("  apps it manages. Run the installed bundle:")
            print("    /Applications/Stow.app/Contents/MacOS/Stow --arrange")
            exit(2)
        }
        guard AXIsProcessTrusted() else {
            print("  FATAL: no Accessibility grant, so synthesised events are discarded.")
            exit(2)
        }
        guard !SpacerItem.otherInstanceRunning() else {
            print("  FATAL: Stow is already running. Two processes would each own a seam and")
            print("  contend over the bar's layout, and the live app's expanded seam hides the")
            print("  items this needs to move.")
            print("")
            print("    osascript -e 'quit app \"Stow\"' && \\")
            print("      /Applications/Stow.app/Contents/MacOS/Stow --arrange; open -a Stow")
            exit(2)
        }

        let store = Store()
        let zones = store.config.zoneByBundleID ?? [:]
        guard !zones.isEmpty else {
            print("  No zones are set, so there is nothing to arrange. Set an app to Tucked in")
            print("  Arrange first, then run this.")
            exit(1)
        }

        if let screen = NSScreen.main {
            print("  display        : \(screen.localizedName) \(Int(screen.frame.width))pt wide")
        }
        print("  zones set      : "
              + zones.map { "\($0.key.split(separator: ".").last ?? "?")=\($0.value.rawValue)" }
                  .sorted().joined(separator: " "))

        let hider = HideController()

        // BASELINE: the shipped seam-moving path, timed, so the comparison is against reality
        // rather than against the numbers in a commit message.
        print("")
        print("  BASELINE, the shipped path (moves the seam, searches for a slot)")
        let baselineBegan = Date()
        hider.timingSink = { print("  \($0)") }
        hider.applyPersistedPlan(from: store.config)
        hider.timingSink = nil
        let baselineCost = Date().timeIntervalSince(baselineBegan)
        print("  total          : \(String(format: "%.2f", baselineCost))s")
        reportBar(label: "bar after the baseline", zones: zones, hider: hider)

        // THE NEW PATH. Run twice: once from wherever the baseline left the bar, and once more
        // to show what an arrange costs when nothing needs moving, which is the common case
        // during a burst of drags.
        print("")
        print("  NEW PATH, moving apps around a stationary seam")
        let first = hider.arrangeByMovingItems(from: store.config)
        report(first, label: "first arrange")

        let second = hider.arrangeByMovingItems(from: store.config)
        report(second, label: "second arrange (nothing should need moving)")

        reportBar(label: "bar after the new path", zones: zones, hider: hider)

        print("")
        print(String(repeating: "-", count: 68))
        print("  seam-moving path : \(String(format: "%.2f", baselineCost))s")
        print("  app-moving path  : \(String(format: "%.2f", first.cost))s cold,"
              + " \(String(format: "%.2f", second.cost))s when already arranged")
        print("")
        if first.isClean, second.isClean {
            print("  Both arranges were clean. The seam did not move for either.")
        } else {
            print("  NOT CLEAN, so this is not ready to replace the shipped path:")
            for f in first.failed + second.failed {
                print("    \(f.bundleID): \(f.reason)")
            }
        }
        exit(0)
    }

    private static func report(_ outcome: Outcome, label: String) {
        print("    \(label): \(String(format: "%.2f", outcome.cost))s"
              + "  moved \(outcome.moved.count),"
              + " already correct \(outcome.alreadyCorrect.count),"
              + " failed \(outcome.failed.count)")
        for bundle in outcome.moved {
            print("      moved    \(bundle)")
        }
        for f in outcome.failed {
            print("      FAILED   \(f.bundleID): \(f.reason)")
        }
    }

    /// Prints whether every app Stow can act on is on the side its zone requires, in the TIDY
    /// state, which is the state a user is in.
    ///
    /// Checks EVERY app, not just the ones named in the config. An app absent from the config
    /// defaults to pinned, so it must be visible, and checking only the configured ones missed
    /// the worst possible outcome: a wiring bug that swept AuthBar, Murmur, 1Password, Vendor Agent and
    /// NoteBuddy off the bar was reported as "0 zoned apps on the wrong side", because none of
    /// those five appears in a config that names only two tucked apps.
    ///
    /// Checked against the bar rather than against "did the command return", because an arrange
    /// that finishes and leaves an app on the wrong side is the failure that matters and is
    /// invisible from a return value.
    private static func reportBar(label: String, zones: [String: Zone], hider: HideController) {
        hider.tidy()
        // Let the seam finish expanding before reading which items survived it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let visible = Set(BarItemOwners.refreshCache().map(\.bundleID))
        let ownBundle = Bundle.main.bundleIdentifier

        // Every app Stow knows about, which includes the ones currently hidden: a hidden app has
        // no live position, so `BarHomes` is the only record that it exists at all.
        var known = Set(hider.currentCandidates().map(\.bundleID))
        known.formUnion(zones.keys)
        // `cannotBeAddressedIndividually`, matching the arranger this verifies.
        //
        // It filtered on `isApple` and that put the bug's own blind spot in the checker written to
        // catch it. The line above deliberately unions in every zoned bundle id so a wrongly-placed
        // app cannot hide; filtering out every `com.apple.*` then removed the ones the arranger
        // genuinely zones, so a config tucking `com.apple.KerberosMenuExtra` could land it on the
        // wrong side, print nothing, and not increment `wrong`. The verifier's universe must be the
        // arranger's universe, which is the gate in `BarArranger.arrange` and the matching one in
        // `isArranged`. Named rather than cited by line: the previous version of this comment gave
        // line numbers, they drifted, the replacement gave the corrected numbers, and those drifted
        // too within the same commit that wrote them. Hence no numbers at all.
        known = known.filter { bundle in
            VisibleRowIdentity.cannotBeAddressedIndividually(bundle) == false
                && bundle != ownBundle
        }

        print("")
        print("  \(label), in the TIDY state:")
        var wrong = 0
        for bundle in known.sorted() {
            let zone = zones[bundle] ?? .pinned
            let onBar = visible.contains(bundle)
            let shouldBeOnBar = zone == .pinned
            let ok = onBar == shouldBeOnBar
            if !ok { wrong += 1 }
            print("    \(bundle.padding(toLength: 34, withPad: " ", startingAt: 0))"
                  + "\(zone.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
                  + (onBar ? "on bar" : "off bar")
                  + (ok ? "" : "   <- WRONG"))
        }
        print("    apps on the wrong side: \(wrong) of \(known.count)")
    }
}
