import AppKit

extension ItemMover {

    /// `Stow --move`: exercises the item mover on the real bar, in both directions, and puts
    /// the bar back exactly as it was found.
    ///
    /// This is the gate for a whole change of approach. Stow currently arranges by moving its
    /// own seam to fit the apps, which costs a measured 0.415s per reposition and about ten of
    /// them per drag. If items can be moved instead, the seam never moves, and a re-zone costs
    /// one move per app. So this has to answer three things honestly:
    ///
    ///   1. Does a synthesised move work at all on this OS?
    ///   2. What does one cost, against the 0.415s it would replace?
    ///   3. How OFTEN does it work? A mechanism that lands half the time is not a foundation.
    ///
    /// It reports every attempt rather than a summary verdict, because an early version of
    /// this measurement recorded 3.0s failures that were successful no-ops misread by a
    /// frame-delta check, and a summary would have hidden that.
    static func runMoveAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - move")
        print(String(repeating: "=", count: 68))

        guard Bundle.main.bundleIdentifier != nil else {
            print("  FATAL: no bundle identifier, so Stow cannot tell its own items from the")
            print("  apps it manages. Run the installed bundle instead:")
            print("    /Applications/Stow.app/Contents/MacOS/Stow --move")
            exit(2)
        }
        guard AXIsProcessTrusted() else {
            print("  FATAL: no Accessibility grant, so synthesised events are discarded.")
            print("  System Settings > Privacy & Security > Accessibility, and enable Stow.")
            exit(2)
        }

        // REFUSE while the app is live. This is not fussiness; a run against a managed bar is
        // meaningless and actively misleading.
        //
        // The live app keeps its tuck seam EXPANDED to about 5,000pt, which sweeps everything
        // to its left off the visible bar. So an item this moves leftward lands in the hidden
        // run, disappears from the scan, and every subsequent attempt reports "not on the bar".
        // Measured exactly that way on a live bar: 1 of 6 landed and the five failures named
        // the wrong cause entirely.
        //
        // Worse, the expanded seam was itself offered as a neighbour to move items next to,
        // because a 5,016pt window spanning x-3862 to x1154 does intersect the bar rect and so
        // passed an `isOnScreen` filter.
        guard !SpacerItem.otherInstanceRunning() else {
            print("  FATAL: Stow is already running, and its seam is expanded, so items moved")
            print("  leftward vanish into the hidden run and this measures nothing.")
            print("")
            print("  Quit Stow first, then run this, then reopen it:")
            print("    osascript -e 'quit app \"Stow\"' && \\")
            print("      /Applications/Stow.app/Contents/MacOS/Stow --move; open -a Stow")
            exit(2)
        }

        let original = barItems()
        guard original.count >= 4 else {
            print("  FATAL: only \(original.count) items on the bar; need four to shuffle one")
            print("  between two neighbours without touching the ends.")
            exit(1)
        }

        // Name the display, because which slots exist and how items pack depends on it, and a
        // result read against the wrong bar is how earlier measurements misled.
        if let screen = NSScreen.main {
            print("  display        : \(screen.localizedName) \(Int(screen.frame.width))pt wide")
        }
        print("  items on bar   : \(original.count)")
        print("")
        print("  bar as found, left to right:")
        for item in original {
            print("    win\(item.windowNumber) x\(Int(item.frame.minX)) w\(Int(item.frame.width))")
        }

        // The hosting process. On macOS 26 this is Control Center for every item, which is
        // exactly why the move targets a window id instead.
        let hostPID = original[0].ownerPID
        print("")
        print("  hosting pid    : \(hostPID)"
              + " (\(NSRunningApplication(processIdentifier: hostPID)?.localizedName ?? "?"))")

        // Work in the MIDDLE of the run, not at either end. The far left is bounded by the
        // placement floor and the far right by Control Center's own items, and a move that
        // fails against a boundary would be indistinguishable from the mechanism failing.
        let mover = original[1]
        let leftNeighbour = original[0]
        let rightNeighbour = original[2]

        print("")
        print("  moving win\(mover.windowNumber), between win\(leftNeighbour.windowNumber)"
              + " and win\(rightNeighbour.windowNumber)")
        print("  the pointer is hidden and warped back for each move, so it should not appear")
        print("  to jump; it IS moved briefly, which is unavoidable when synthesising a drag")
        print("")

        var costs: [TimeInterval] = []
        var failures: [String] = []

        func run(_ label: String, _ destination: Destination) {
            do {
                let cost = try move(windowID: mover.windowNumber,
                                    to: destination, hostPID: hostPID)
                costs.append(cost)
                print("    \(label): ok      \(String(format: "%.3f", cost))s")
            } catch {
                failures.append(label)
                print("    \(label): FAILED  \(error)")
            }
        }

        // Alternate directions. Direction matters: an earlier probe landed every rightward
        // move and failed every leftward one, which is the kind of asymmetry a single-direction
        // test would have missed entirely.
        print("  attempts:")
        for round in 1...3 {
            run("round \(round) right of win\(rightNeighbour.windowNumber)",
                .rightOf(rightNeighbour.windowNumber))
            run("round \(round) left of win\(leftNeighbour.windowNumber)",
                .leftOf(leftNeighbour.windowNumber))
        }

        print("")
        print(String(repeating: "-", count: 68))
        if costs.isEmpty {
            print("  NOTHING LANDED. The mechanism does not work here, so the move-the-apps")
            print("  approach is not available and the seam must keep chasing the apps.")
        } else {
            let mean = costs.reduce(0, +) / Double(costs.count)
            print("  landed \(costs.count) of 6, failed \(failures.count)")
            print("  per move       : min \(String(format: "%.3f", costs.min() ?? 0))s"
                  + "  mean \(String(format: "%.3f", mean))s"
                  + "  max \(String(format: "%.3f", costs.max() ?? 0))s")
            print("")
            print("  Stow's seam reposition, for comparison: mean 0.415s, and an apply spends")
            print("  about ten of them. One move per re-zoned app replaces all of that.")
            if !failures.isEmpty {
                print("")
                print("  NOT YET A FOUNDATION. \(failures.count) of 6 failed, so this cannot")
                print("  carry the arrange path until it is reliable:")
                for f in failures { print("    - \(f)") }
            }
        }

        // PUT THE BAR BACK. A diagnostic that rearranges a user's menu bar and leaves it that
        // way is worse than no diagnostic: it costs them a manual command-drag per item to
        // undo, and they did not ask for the arrangement.
        print("")
        print("  restoring the original order...")
        let restored = restore(order: original.map(\.windowNumber), hostPID: hostPID)
        let now = barItems().map(\.windowNumber)
        print("  order now      : \(now.map { "win\($0)" }.joined(separator: " "))")
        print(restored
              ? "  RESTORED to the original order."
              : "  NOT fully restored. Command-drag any item that looks out of place;"
                + " nothing here persists an arrangement.")
        exit(0)
    }

    /// Rebuilds a known left-to-right order by moving each item to the right of the one before
    /// it. Bounded, and reports whether it succeeded rather than assuming.
    ///
    /// Insertion order matters: fixing the leftmost first and working right means each move has
    /// an already-correct anchor to its left, so one failure does not cascade.
    private static func restore(order: [CGWindowID], hostPID: pid_t) -> Bool {
        guard order.count > 1 else { return true }
        for index in 1..<order.count {
            let previous = order[index - 1]
            let current = order[index]
            guard barItems().contains(where: { $0.windowNumber == current }),
                  barItems().contains(where: { $0.windowNumber == previous })
            else { continue }
            if isPositioned(current, at: .rightOf(previous)) { continue }
            do {
                try move(windowID: current, to: .rightOf(previous), hostPID: hostPID)
            } catch {
                // Keep going. A later item may still be placeable, and a partial restore is
                // better than abandoning the bar at the first refusal.
                continue
            }
        }
        // Compare only the items that STILL EXIST, in order.
        //
        // A window number is not stable for a session: Control Center recreates an item's
        // window and the number changes underneath. Measured during a run, win55245 became
        // win65229 while the bar was otherwise untouched. Comparing the full number list
        // against the original therefore reported "not restored" for a bar that was visually
        // correct, which is a false alarm that would send the next reader chasing a
        // non-existent bug.
        let surviving = Set(barItems().map(\.windowNumber))
        let expected = order.filter { surviving.contains($0) }
        let actual = barItems().map(\.windowNumber).filter { expected.contains($0) }
        return actual == expected
    }
}
