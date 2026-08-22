import AppKit
import CoreGraphics

/// `Stow --probe` — the hard gate.
///
/// The design in the mock rests on one unverified assumption: that
/// `CGWindowListCopyWindowInfo` still reports `kCGWindowBounds` for a status item that
/// the spacer has pushed off the visible menu bar. If it does not, `RevealCoordinator`
/// cannot know how far to shrink the spacer, reveal-one is impossible, and mirroring
/// via ScreenCaptureKit becomes mandatory along with a Screen Recording grant.
///
/// So this runs BEFORE any UI is built. It:
///   1. reports the environment, including whether geometry arrives without a Screen
///      Recording grant,
///   2. takes a baseline scan of the bar,
///   3. creates a real spacer item, expands it to push the run off the bar, re-scans,
///      and compares,
///   4. prints a single VERDICT line for risk 3,
///   5. measures `kAXPressAction` coverage, which decides how often the expensive
///      path will run at all,
///   6. removes the spacer and exits.
///
/// Deliberately not a unit test. The question is about the live window server, and no
/// amount of pure logic can answer it.
@MainActor
enum Probe {

    /// How wide to make the spacer during phase 2. Larger than any real display, so
    /// every non-pinned item is guaranteed pushed off rather than merely shuffled.
    private static let pushLength: CGFloat = 10_000

    /// Whether a measured spacer width counts as actually expanded.
    ///
    /// NOT a fraction of `pushLength`. The window server clamps a 10,000pt request to
    /// whatever it likes and the figure varies by display: measured 5016pt on a
    /// notched built-in and 4896pt on a 2560x1080 external. A "half the request"
    /// threshold put those two on opposite sides of the line, so the same working
    /// push was reported as honoured on one display and as "clamped or ignored, this
    /// run tests nothing" on the other, which was simply false: the victim moved
    /// 4,990pt.
    ///
    /// What matters is whether the spacer is wide enough to shove a real bar's worth
    /// of items off the edge, so the test is an absolute width against the widest
    /// plausible display rather than a ratio against a request nobody honours
    /// literally.
    private static func spacerExpanded(_ width: CGFloat) -> Bool {
        width >= 2_000
    }

    static func runAndExit() -> Never {
        // Accessory policy: no Dock tile, no menu, but a real NSApplication so
        // NSStatusItem has a run loop to lay out in.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        line("Stow \(StowVersion.display) — probe")
        line(String(repeating: "=", count: 68))

        // ---- 1. environment -------------------------------------------------
        section("1. ENVIRONMENT")
        let trusted = PressActionProbe.isTrusted
        line("  accessibility granted : \(trusted ? "YES" : "NO")")
        if !trusted {
            line("    ! phase 4 will be skipped, and reveal-one needs this to click.")
            line("    ! grant in System Settings > Privacy & Security > Accessibility,")
            line("      then re-run. Risk 3 itself does NOT need it.")
        }

        guard let screen = NSScreen.main else {
            line("  FATAL: no main screen"); exit(2)
        }
        let barRect = BarScanner.menuBarRect(for: screen)
        let notch = BarScanner.notchWidth(for: screen)
        line("  display               : \(Int(screen.frame.width))x\(Int(screen.frame.height))"
             + " @ \(screen.backingScaleFactor)x")
        line("  menu bar band (quartz): \(fmt(barRect))")
        line("  status bar thickness  : \(NSStatusBar.system.thickness) pt")
        line("  notch dead zone       : \(Int(notch)) pt \(notch == 0 ? "(notchless)" : "")")
        line("  status window layer   : \(BarScanner.statusWindowLayer)")

        // ---- 2. baseline ----------------------------------------------------
        section("2. BASELINE SCAN")
        let before = BarScanner.scan(menuBarRect: barRect)
        line("  windows inspected     : \(before.totalWindowsInspected)")
        line("  status items found    : \(before.items.count)")
        line("  kCGWindowName present : \(before.sawWindowNames ? "YES" : "NO")")
        line(before.sawWindowNames
             ? "    note: names visible, so Screen Recording appears GRANTED. Geometry"
             + "\n    would still arrive without it; this run cannot prove that."
             : "    GOOD: names withheld, so Screen Recording is NOT granted, and the"
             + "\n    geometry above arrived anyway. The no-capture design is confirmed.")
        line("")
        if before.items.isEmpty {
            line("  FATAL: no status items matched. Either the layer filter is wrong or")
            line("  the Y-band tolerance is too tight. Both are in BarScanner.scan.")
            exit(3)
        }
        table(before.items)

        // ---- 3. RISK 3 ------------------------------------------------------
        section("3. RISK 3 — off-screen frame readability")

        // Identify our own spacer by WINDOW NUMBER, never by PID.
        //
        // On macOS 26 every status item window — including one this process just
        // created — is attributed to the ControlCenter process, so the old
        // `ownerPID != ourPID` filter never matched and silently left the spacer in
        // the subject list. Window numbers are unique per window and are the only
        // reliable way to tell our item from the ones under test.
        let beforeNumbers = Set(before.items.map(\.windowNumber))
        let beforeByNumber = Dictionary(uniqueKeysWithValues:
            before.items.map { ($0.windowNumber, $0.frame) })

        let spacer = NSStatusBar.system.statusItem(withLength: pushLength)
        spacer.button?.title = ""
        line("  created spacer, length \(Int(pushLength)) pt. settling…")
        settle(0.9)

        let after = BarScanner.scan(menuBarRect: barRect)
        let ourSpacer = after.items.first { !beforeNumbers.contains($0.windowNumber) }
        let subjects = after.items.filter { $0.windowNumber != ourSpacer?.windowNumber }

        // Did the spacer actually take effect? Without this, a clamped or ignored
        // spacer is indistinguishable from items that refuse to be pushed, and the
        // gate would report INCONCLUSIVE for two completely different causes.
        if let s = ourSpacer {
            line("  our spacer frame      : \(fmt(s.frame))  (requested \(Int(pushLength)) pt)")
            line("  spacer honoured       : \(spacerExpanded(s.frame.width) ? "YES" : "NO — clamped to a length that pushes nothing")")
        } else {
            line("  our spacer frame      : NOT FOUND in scan — it never became a window")
        }

        // Movement evidence: match items across the two scans by window number and
        // report how far each one actually travelled.
        var moved = 0
        var deltas: [String] = []
        for item in subjects {
            guard let old = beforeByNumber[item.windowNumber] else { continue }
            let dx = item.frame.minX - old.minX
            if abs(dx) > 0.5 {
                moved += 1
                deltas.append("    \(pad(item.ownerName, 22)) x\(Int(old.minX)) -> x\(Int(item.frame.minX))"
                              + "  (dx \(Int(dx)))  w\(Int(item.frame.width))")
            }
        }
        line("  items that MOVED      : \(moved) of \(subjects.count)")
        for d in deltas.prefix(20) { line(d) }

        let pushed = subjects.filter { !$0.isOnScreen }
        let readable = pushed.filter { $0.frame.width > 0 }

        line("  items still enumerable: \(subjects.count) (was \(before.items.count))")
        line("  now OFF the bar       : \(pushed.count)")
        line("  of those, width > 0   : \(readable.count)")
        line("")
        table(pushed)

        let spacerHonoured = spacerExpanded(ourSpacer?.frame.width ?? 0)
        let verdict: String
        if pushed.isEmpty && !spacerHonoured {
            verdict = "INCONCLUSIVE — the spacer was NOT honoured (measured"
                    + " \(Int(ourSpacer?.frame.width ?? 0)) pt of \(Int(pushLength)) requested),"
                    + " so nothing was ever pushed and this run tests nothing."
                    + " The push mechanism itself is the thing to fix, not the reader."
        } else if pushed.isEmpty && moved == 0 {
            verdict = "INCONCLUSIVE here — the spacer WAS honoured but no EXISTING item"
                    + " moved, because a freshly created status item is laid out"
                    + " LEFTMOST and only displaces items to its own LEFT. Every item"
                    + " above sits to its RIGHT. This says nothing about frame"
                    + " readability, and nothing about immunity — see phase 3b, which"
                    + " creates a victim to the spacer's left and answers the gate."
        } else if pushed.isEmpty {
            verdict = "INCONCLUSIVE — \(moved) item(s) moved but none left the bar."
                    + " The spacer is too small, or the bar absorbed it."
        } else if readable.count == pushed.count {
            verdict = "PASS — every pushed item kept a readable frame."
                    + " reveal-one is viable. No Screen Recording needed."
        } else if readable.isEmpty {
            verdict = "FAIL — pushed items report no usable width."
                    + " reveal-one is DEAD; mirroring via ScreenCaptureKit is mandatory."
        } else {
            verdict = "PARTIAL — \(readable.count) of \(pushed.count) kept a frame."
                    + " Reveal-one works per-item; the rest need a fallback."
        }
        line("  >>> RISK 3 VERDICT: \(verdict)")

        // ---- 4. press-action coverage --------------------------------------
        section("4. PRESS-ACTION COVERAGE (the zero-delta path)")

        // The earlier version of this phase probed `item.ownerPID`, which on this
        // OS is the Control Center process for every item without exception. A
        // loop over `subjects` therefore asked ONE process the same question N
        // times and reported its single answer N times over: a fabricated
        // per-item number, not a measurement. Refusing to print it was correct
        // given what the phase actually asked.
        //
        // `BarItemOwners.identities()` asks the right question instead: it asks each
        // RUNNING APPLICATION for its own `AXExtrasMenuBar`, so the pid it returns
        // for a given item is the pid whose own app answers for that item, never
        // Control Center's. Unlike `claims()`, it retains tucked items at negative
        // x, which are exactly the items this coverage check must include.
        if !trusted {
            line("  SKIPPED: accessibility not granted.")
        } else {
            let identities = BarItemOwners.identities()
            if identities.isEmpty {
                line("  UNMEASURABLE: no running application exposed an")
                line("  AXExtrasMenuBar identity, so no owning pid could be resolved.")
            } else {
                let excluded = ourSpacer.map { Set([$0.windowNumber]) } ?? []
                let split = coverageSplit(subjects: subjects, identities: identities,
                                          screenWidth: screen.frame.width,
                                          excluding: excluded)
                var free = 0
                for (item, owner) in split.resolved {
                    let path = PressActionProbe.probe(pid: owner.pid)
                    if path == .pressAction { free += 1 }
                    line("  \(pad(owner.name, 26)) \(path.rawValue)"
                         + "  (host reported: \(pad(item.ownerName, 16)))")
                }
                for item in split.unresolved {
                    line("  \(pad(item.ownerName, 26)) UNRESOLVED, no owner claimed this frame")
                }
                line("")
                if let detail = coverageDetail(free: free, resolved: split.resolved.count,
                                                unresolved: split.unresolved.count) {
                    line("  >>> \(detail).")
                    line("      The remaining \(split.resolved.count - free) resolved item(s) need"
                         + " the phase-3 mechanism.")
                } else {
                    line("  >>> UNMEASURABLE: none of \(subjects.count) item(s) resolved to an")
                    line("      owning application.")
                }
            }
        }

        // ---- 3b. self-contained push test -----------------------------------
        section("3b. SELF-CONTAINED PUSH TEST — the decisive one")

        // Phase 3 cannot answer the gate on this OS for a STRUCTURAL reason, not a
        // bug: a newly created status item is laid out LEFTMOST, so it has nothing to
        // its own left to push off. Bartender and Ice only push because the user
        // command-drags their separator to sit BETWEEN existing items.
        //
        // So stop depending on other apps' items and build the push ourselves. Order
        // is the whole trick: newest lands leftmost, so the spacer must already exist
        // for a victim created afterwards to sit to the spacer's LEFT. Then growing
        // the spacer pushes our own victim off the left edge, and the only question
        // that matters is whether that victim still reports a usable frame.
        spacer.length = 10
        settle(0.6)

        let preVictim = Set(BarScanner.scan(menuBarRect: barRect).items.map(\.windowNumber))
        let victim = NSStatusBar.system.statusItem(withLength: 44)
        victim.button?.title = "RV"
        settle(0.9)

        let withVictim = BarScanner.scan(menuBarRect: barRect)
        guard let victimSeated = withVictim.items.first(where: {
            !preVictim.contains($0.windowNumber)
        }) else {
            line("  FATAL: our own victim item never became an enumerable window.")
            line("  Without it this phase cannot run. Everything above still stands.")
            NSStatusBar.system.removeStatusItem(victim)
            NSStatusBar.system.removeStatusItem(spacer)
            exit(4)
        }
        let victimNumber = victimSeated.windowNumber
        line("  victim seated         : \(fmt(victimSeated.frame))"
             + "  on-bar: \(victimSeated.isOnScreen ? "yes" : "no")")

        // Now push it.
        spacer.length = pushLength
        settle(1.2)

        let pushedScan = BarScanner.scan(menuBarRect: barRect)
        let victimAfter = pushedScan.items.first { $0.windowNumber == victimNumber }

        let gateAnswer: String
        if let v = victimAfter {
            let dx = v.frame.minX - victimSeated.frame.minX
            line("  victim after push     : \(fmt(v.frame))"
                 + "  on-bar: \(v.isOnScreen ? "yes" : "no")  (dx \(Int(dx)))")
            line("  still enumerable      : YES")
            line("  width readable        : \(v.frame.width > 0 ? "YES (\(Int(v.frame.width)) pt)" : "NO (zero)")")

            if abs(dx) < 0.5 && v.isOnScreen {
                gateAnswer = "INCONCLUSIVE — our own victim did not move either, so the"
                    + " spacer cannot displace ANY item on this OS. The push mechanism"
                    + " the design depends on does not work here."
            } else if v.frame.width > 0 {
                gateAnswer = "PASS — a status item pushed off the visible bar still"
                    + " reports kCGWindowBounds with non-zero width"
                    + " (\(Int(v.frame.width)) pt at x\(Int(v.frame.minX))). reveal-one is"
                    + " viable and no Screen Recording grant is required."
            } else {
                gateAnswer = "FAIL — the pushed item is still enumerable but reports ZERO"
                    + " width, so its size cannot be read once off the bar. reveal-one is"
                    + " dead; mirroring via ScreenCaptureKit becomes mandatory."
            }
        } else {
            line("  victim after push     : NOT FOUND — vanished from the window list")
            line("  still enumerable      : NO")
            gateAnswer = "FAIL — the pushed item disappeared from"
                + " CGWindowListCopyWindowInfo entirely, so neither its position nor"
                + " its width can be read. reveal-one is dead; mirroring is mandatory."
        }
        line("")
        line("  >>> GATE ANSWER: \(gateAnswer)")

        NSStatusBar.system.removeStatusItem(victim)
        spacer.length = 10
        settle(0.3)

        // ---- 5. budget ------------------------------------------------------
        section("5. BAR BUDGET (points, not slots)")
        let onBar = before.items.filter(\.isOnScreen)
        let occupiedWidths = BarBudget.occupiedWidths(in: before.items,
                                                       screenWidth: screen.frame.width,
                                                       excluding: [])
        let appMenuWidth = MenuWidthProbe.measureFrontmostAppMenuWidth()
        let systemTrailingWidth = MenuWidthProbe.measureSystemTrailingWidth()
        let budget = BarBudget(
            screenWidth: screen.frame.width,
            // Fed 0 only when the field could not be measured, never as a claim
            // that the true width is zero. Whichever field lands here as 0 for
            // that reason gets its own caveat printed below; a field that WAS
            // measured, even to a genuine 0, gets none.
            appMenuWidth: appMenuWidth ?? 0,
            notchWidth: notch,
            systemTrailingWidth: systemTrailingWidth ?? 0,
            occupiedWidths: occupiedWidths)
        line("  \(budget.arithmetic)")
        line("  widest item on bar    : \(Int(occupiedWidths.max() ?? 0)) pt")
        let mechanisms = onBar.count - occupiedWidths.count
        if mechanisms > 0 {
            line("  excluded mechanisms  : \(mechanisms) oversized spacer item(s)")
        }

        // Only the field that genuinely could not be measured gets a caveat.
        // Printing one for a field that WAS measured would be the same kind of
        // lie as the old blanket "upper bound" note this replaces, just aimed at
        // the wrong field.
        if appMenuWidth == nil {
            line("  NOTE: appMenuWidth not measured (Accessibility not granted, or the")
            line("  frontmost app's AXMenuBar could not be read). `usable` above is an")
            line("  upper bound on that field.")
        }
        if systemTrailingWidth == nil {
            line("  NOTE: systemTrailingWidth not measured (Control Center's own items")
            line("  could not be told apart from third-party ones sharing its process).")
            line("  `usable` above is an upper bound on that field.")
        }
        if appMenuWidth != nil && systemTrailingWidth != nil {
            line("  both fields measured. `usable` above is a real number, not an upper bound.")
        }

        // ---- teardown -------------------------------------------------------
        NSStatusBar.system.removeStatusItem(spacer)
        settle(0.2)
        section("DONE")
        line("  spacer removed. Paste sections 3 and 4 back to close the gate.")
        exit(0)
    }

    /// Forwards to `BarItemOwners.split`, which is the single implementation.
    ///
    /// Kept as a named entry point because the call site and the tests read better
    /// for it, but it holds no logic of its own. It previously did, and so did
    /// `BarDoctor`, with the two bodies identical and a test asserting they agreed.
    /// That test was the right instinct about the wrong problem: the fix is one
    /// implementation, not two guarded copies.
    static func splitByOwner(_ subjects: [ObservedItem], claims: [BarItemOwners.Owner])
        -> (resolved: [(item: ObservedItem, owner: BarItemOwners.Owner)], unresolved: [ObservedItem]) {
        BarItemOwners.split(subjects, claims: claims)
    }

    static func coverageSplit(subjects: [ObservedItem], identities: [BarItemOwners.Owner],
                              screenWidth: CGFloat, excluding seamWindows: Set<CGWindowID>)
        -> (resolved: [(item: ObservedItem, owner: BarItemOwners.Owner)], unresolved: [ObservedItem]) {
        BarItemOwners.coverageSplit(subjects: subjects, identities: identities,
                                    screenWidth: screenWidth, excluding: seamWindows)
    }

    /// Forwards to `BarItemOwners.coverageSummary`. See `splitByOwner` above for why
    /// this holds no logic of its own.
    nonisolated static func coverageDetail(free: Int, resolved: Int, unresolved: Int) -> String? {
        BarItemOwners.coverageSummary(free: free, resolved: resolved, unresolved: unresolved)
    }

    // MARK: - output helpers

    private static func line(_ s: String) { print(s) }
    private static func section(_ t: String) { print("\n\(t)\n\(String(repeating: "-", count: 68))") }
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
    private static func fmt(_ r: CGRect) -> String {
        "x\(Int(r.minX)) y\(Int(r.minY)) w\(Int(r.width)) h\(Int(r.height))"
    }
    private static func table(_ items: [ObservedItem]) {
        guard !items.isEmpty else { line("  (none)"); return }
        line("  \(pad("OWNER", 26)) \(pad("FRAME", 30)) ON-BAR  BUNDLE")
        for i in items {
            line("  \(pad(i.ownerName, 26)) \(pad(fmt(i.frame), 30))"
                 + " \(i.isOnScreen ? "yes   " : "NO    ") \(i.bundleID ?? "-")")
        }
    }

    /// Let AppKit process status bar layout.
    ///
    /// A plain `sleep` would not do: status item layout happens on the main run loop,
    /// so the loop has to actually turn or the re-scan reads stale geometry.
    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
