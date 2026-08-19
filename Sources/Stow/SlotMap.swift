import AppKit
import CoreGraphics

/// Which positions a seam can reach on this bar, measured. A DIAGNOSTIC, not a placement
/// mechanism.
///
/// This began as a cache meant to replace the binary search in `HideController.moveCut`, on the
/// theory that measuring the placement-to-position mapping once per bar shape would turn a
/// dozen probes into one lookup. That theory is false, and the measurements that killed it are
/// worth keeping because the idea is an obvious one to have again:
///
/// PLACEMENTS DO NOT TRANSFER ACROSS AUTOSAVE IDENTITIES. macOS resolves a status item's
/// position from the preference keyed to its OWN autosave name, against the saved positions of
/// every other named item. Measured on one unchanged bar, moments apart: `pref 1` landed at
/// x1160 under one name and x1516 under another, a 356pt disagreement. So a map measured with a
/// throwaway probe cannot predict where the real seam lands, which is the only thing a
/// placement mechanism needs to do.
///
/// MEASURING PERTURBS WHAT IT MEASURES. Two runs of the same measurement on the same bar found
/// five slots and seven slots, because each probe creates and destroys a real status item and
/// the bar reflows around it.
///
/// IT WAS ALSO NOT FASTER. With the cache in place, first apply 8.25s and second apply 8.26s,
/// so it never stayed warm; end to end it measured 16.02s against the search's 15.09s.
///
/// What survives is genuinely useful, and it is why this file is not simply deleted: the
/// reachable-slot list answers a real question about a display, namely which positions exist at
/// all. On the built-in display that range was 353pt wide, which is what makes
/// `BarPlan.belowPlacementFloor` a real constraint rather than a defensive check: an app sitting
/// right of the rightmost reachable slot cannot be hidden without taking its neighbours along.
@MainActor
enum SlotMap {

    /// One reachable slot: the preference that selects it, and where a seam lands.
    struct Slot: Equatable {
        let placement: Int
        let landingX: CGFloat
    }

    /// Measures the slots reachable on the bar as it stands.
    ///
    /// About four seconds: a dozen probes, each creating a real status item and waiting for the
    /// window server to report where it landed. Deliberately coarse, because the preference
    /// resolves to a slot rather than a pixel and most values are duplicates: ten preferences
    /// between 1 and 700 produced six distinct positions, and everything past 700 landed on the
    /// same one.
    ///
    /// NOT cached, and NOT used to place a seam. Both were tried and both were wrong. See the
    /// type comment: the numbers this returns describe where the PROBE lands, and placements do
    /// not transfer between autosave identities, so they cannot predict the real seam.
    static func reachableSlots() -> [Slot] {
        measure()
    }

    /// Probes the useful range and records the distinct positions found.
    ///
    /// The probe carries no image and its own autosave name, so it never disturbs a real seam's
    /// stored placement, and the name's preference is removed afterwards.
    private static func measure(underName probeName: String = "StowSlotProbe") -> [Slot] {
        let key = "NSStatusItem Preferred Position \(probeName)"
        var found: [Slot] = []

        for placement in probePlacements {
            UserDefaults.standard.set(placement, forKey: key)
            UserDefaults.standard.synchronize()

            let before = currentWindowNumbers()
            let probe = NSStatusBar.system.statusItem(withLength: SpacerItem.restingLength)
            probe.autosaveName = probeName
            probe.button?.image = nil
            probe.button?.title = ""

            var landed: CGFloat?
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, landed == nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                landed = newItemPosition(excluding: before)
            }
            NSStatusBar.system.removeStatusItem(probe)

            // Only positive positions are real. A probe that reports a large negative position
            // was itself pushed off the bar, which means a seam was expanded while measuring and
            // the whole map would be nonsense.
            if let landed, landed > 0 {
                found.append(Slot(placement: placement, landingX: landed))
            }
        }

        UserDefaults.standard.removeObject(forKey: key)

        return collapse(found)
    }

    /// Groups probe results that describe the SAME slot, keeping the smallest preference.
    ///
    /// Clustering, not bucketing. Rounding each position into a fixed-width bucket cannot group
    /// two values that straddle a boundary, which is not a hypothetical: with a 6pt bucket,
    /// x1490 and x1491 rounded to 248 and 249 and survived as two slots one point apart. The
    /// same run also reported x1481 and x1482 separately. Sorting first and then walking, so a
    /// position joins the cluster it is actually near, has no boundary to straddle.
    ///
    /// The smallest preference wins because a smaller value is never further left and is the
    /// least likely to be clamped. The position kept is the one MEASURED for that preference,
    /// never a cluster average, so the map never reports a position no probe observed.
    ///
    /// `nonisolated` and `internal` so it is testable without a status bar: this is the one part
    /// of the map that is pure arithmetic, and it is where the defect was.
    nonisolated static func collapse(_ found: [Slot]) -> [Slot] {
        let ordered = found.sorted { $0.landingX < $1.landingX }
        var clusters: [[Slot]] = []
        for slot in ordered {
            if let last = clusters.last?.last, slot.landingX - last.landingX <= slotJitter {
                clusters[clusters.count - 1].append(slot)
            } else {
                clusters.append([slot])
            }
        }
        return clusters
            .compactMap { $0.min { $0.placement < $1.placement } }
            .sorted { $0.landingX > $1.landingX }
    }

    /// Measures the same placement range under a DIFFERENT autosave name, for the identity test
    /// in `--slots`. Diagnostic only.
    static func measureUnderName(_ name: String) -> [Slot] {
        measure(underName: name)
    }

    /// How much positional jitter counts as the same slot.
    ///
    /// The window server does not report a slot's position to the point. Measured across a
    /// dozen probes on one unchanged bar, one slot reported x1481 and x1482 for two different
    /// preferences, and another reported x1490 and x1491, so anything within a few points is
    /// one slot.
    nonisolated static let slotJitter: CGFloat = 6

    /// Which preferences to probe.
    ///
    /// Chosen from the measured mapping rather than evenly spaced. Positions change quickly at
    /// the low end, one slot every ~40 values, and barely at all past ~500, where everything
    /// collapses onto the leftmost reachable slot. So the probes are dense where the slots are.
    private static let probePlacements = [1, 20, 60, 120, 180, 240, 300, 360, 440, 520, 640, 800]

    private static func currentWindowNumbers() -> Set<CGWindowID> {
        guard let screen = NSScreen.main else { return [] }
        let barRect = BarScanner.menuBarRect(for: screen)
        return Set(BarScanner.scan(menuBarRect: barRect).items.map(\.windowNumber))
    }

    private static func newItemPosition(excluding known: Set<CGWindowID>) -> CGFloat? {
        guard let screen = NSScreen.main else { return nil }
        let barRect = BarScanner.menuBarRect(for: screen)
        return BarScanner.scan(menuBarRect: barRect).items
            .first { !known.contains($0.windowNumber) }?
            .frame.minX
    }
}

extension SlotMap {

    /// `Stow --probecost`: how long ONE seam reposition actually takes, measured repeatedly.
    ///
    /// This is the number that bounds every placement decision in Stow. A bisection spends about
    /// five of these and the correction pass another five, so if a reposition costs 0.45s then a
    /// drag cannot go below roughly 4.5s however the search is arranged, and the effort belongs
    /// in cutting the COUNT rather than reshaping the search.
    ///
    /// Tightening `awaitMeasuredFrame`'s poll from 0.1s to 0.01s was tried first, on the theory
    /// that a probe was mostly waiting out its own polling granularity. It was not: three drags
    /// measured 7.10s, 2.39s and 8.48s, the same spread as before. Hence measuring the
    /// reposition itself rather than guessing a third time.
    static func runProbeCostAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - probecost")
        print(String(repeating: "=", count: 68))

        let seam = SpacerItem(persistPlacement: false)
        _ = seam.awaitMeasuredFrame()

        // Alternate between two placements far enough apart to be different slots, so every
        // reposition is a real move rather than a no-op the window server can shortcut.
        let placements = [1, 300, 1, 300, 1, 300, 1, 300]
        var costs: [TimeInterval] = []
        for placement in placements {
            let began = Date()
            let landed = seam.reposition(placement: placement, length: SpacerItem.restingLength)
            let cost = Date().timeIntervalSince(began)
            costs.append(cost)
            print("  pref \(placement) -> "
                   + (landed.map { "x\(Int($0))" } ?? "unmeasured")
                   + "  in \(String(format: "%.3f", cost))s")
        }

        seam.remove()

        guard let lowest = costs.min(), let highest = costs.max() else { exit(1) }
        let mean = costs.reduce(0, +) / Double(costs.count)
        print("")
        print("  per reposition   : min \(String(format: "%.3f", lowest))s"
               + "  mean \(String(format: "%.3f", mean))s"
               + "  max \(String(format: "%.3f", highest))s")
        print("")
        print("  So a five-probe bisection costs about \(String(format: "%.1f", mean * 5))s,"
               + " and the two a drag runs about \(String(format: "%.1f", mean * 10))s.")
        exit(0)
    }
}

extension SlotMap {

    /// `Stow --slots`: measures the map twice, once with a seam EXPANDED and once at REST,
    /// and reports what each costs and finds.
    ///
    /// Exists because the difference between those two states was a 12-second drag that also
    /// moved nothing, and neither `--seam` nor `--apply` reproduces it: both rest the bar
    /// before doing anything, so both measure the good case only. This mode deliberately
    /// measures the bad one first.
    ///
    /// What it proves: while a seam is expanded it is about 10,000pt wide, so every probe this
    /// map creates is pushed off the bar and reports a non-positive position. `measure()`
    /// discards those, so the map comes back EMPTY after waiting out all twelve one-second
    /// deadlines. An empty map yields no placement, so the caller both paid the full cost and
    /// moved no seam. Resting first is what makes the probes land on the bar at all.
    static func runSlotsAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        print("Stow \(StowVersion.display) - slots")
        print(String(repeating: "=", count: 68))

        // `persistPlacement: false` for the same reason `--seam` uses it: the main instance is
        // usually live, and an autosaveName collision silently denies this item a window.
        let seam = SpacerItem(persistPlacement: false)
        _ = seam.awaitMeasuredFrame()

        // Name the display. The slots are a property of ONE bar, and reading a result measured
        // on the built-in screen as though it described an external one is how a 76pt reachable
        // range gets mistaken for a 2,560pt one.
        if let screen = NSScreen.main {
            print("display          : \(screen.localizedName)"
                   + "  \(Int(screen.frame.width))pt wide")
        }

        print("")
        print("EXPANDED  (a seam pushing, as during a drag while items are hidden)")
        seam.expand(toPush: 10_000)
        // POLL, never sleep. A 0.4s sleep here read the PREVIOUS width in both passes, which
        // inverted the whole result: the expanded pass measured a clear bar and the rested pass
        // measured a 5,016pt seam still in force.
        let expandedWidth = seam.awaitMeasuredWidth(satisfying: { $0 > 1_000 })
        guard let expandedWidth else {
            print("  the seam never became wide, so this pass cannot test anything.")
            print("  Nothing below should be read as evidence about seam width.")
            seam.remove()
            exit(1)
        }
        print("  seam width       : \(Int(expandedWidth))pt (settled)")
        var started = Date()
        let expandedSlots = reachableSlots()
        let expandedCost = Date().timeIntervalSince(started)
        print("  elapsed          : \(String(format: "%.2f", expandedCost))s")
        print("  slots found      : \(expandedSlots.count)")

        print("")
        print("AT REST   (every seam resting, which is what a measurement needs)")
        seam.expand(toPush: SpacerItem.restingLength)
        let restedWidth = seam.awaitMeasuredWidth(satisfying: { $0 < 100 })
        guard let restedWidth else {
            print("  the seam never returned to rest, so this pass cannot test anything.")
            seam.remove()
            exit(1)
        }
        print("  seam width       : \(Int(restedWidth))pt (settled)")
        started = Date()
        let restedSlots = reachableSlots()
        let restedCost = Date().timeIntervalSince(started)
        print("  elapsed          : \(String(format: "%.2f", restedCost))s")
        print("  slots found      : \(restedSlots.count)")
        for slot in restedSlots {
            print("    pref \(slot.placement) -> x\(Int(slot.landingX))")
        }
        if let leftmost = restedSlots.map(\.landingX).min(),
           let rightmost = restedSlots.map(\.landingX).max() {
            print("  reachable range  : x\(Int(leftmost)) to x\(Int(rightmost))"
                   + "  (\(Int(rightmost - leftmost))pt)")
            print("    A seam can only ever sit at one of these positions, so an app sitting")
            print("    right of x\(Int(rightmost)) cannot be hidden without taking its")
            print("    neighbours with it.")
        }

        print("")
        print("MEASUREMENT IS NOT REPRODUCIBLE  (same bar, measured again)")
        started = Date()
        let secondPass = reachableSlots()
        print("  elapsed          : "
               + "\(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        print("  slots found      : \(secondPass.count)"
               + (secondPass.count == restedSlots.count
                  ? "  (same count as above)"
                  : "  (DIFFERENT from the \(restedSlots.count) above)"))

        // THE decisive test for whether this whole approach can work.
        //
        // `measure()` probes with a throwaway item named `StowSlotProbe`, and the map it
        // produces is then used to place a REAL seam named `RailSpacer`. macOS resolves a
        // status item's position from the placement preference keyed to its OWN autosave name,
        // against the saved positions of every other named item. If two identities do not agree
        // on where a given preference lands, a map measured under one cannot predict the other,
        // and no tolerance, cache rule or ordering fixes that: the numbers simply do not
        // transfer.
        //
        // Measured on the same unchanged bar, in one process, moments apart.
        print("")
        print("IDENTITY TRANSFER  (does a map measured under one name predict another?)")
        let underA = measureUnderName("StowIdentityTestA")
        let underB = measureUnderName("StowIdentityTestB")
        print("  name A found     : \(underA.count) slots")
        print("  name B found     : \(underB.count) slots")
        var agreements = 0
        var disagreements = 0
        for a in underA {
            guard let b = underB.first(where: { $0.placement == a.placement }) else { continue }
            let delta = abs(a.landingX - b.landingX)
            if delta <= slotJitter { agreements += 1 } else { disagreements += 1 }
            print("    pref \(a.placement): A x\(Int(a.landingX)) vs B x\(Int(b.landingX))"
                   + "  delta \(Int(delta))pt"
                   + "  \(delta <= slotJitter ? "agree" : "DISAGREE")")
        }
        print("  agree \(agreements), disagree \(disagreements)")
        if disagreements > agreements {
            print("  => Placements DO NOT transfer across autosave identities. A map measured")
            print("     with a probe cannot predict where the real seam lands, so SlotMap")
            print("     cannot work by measuring under a throwaway name.")
        } else if disagreements == 0 {
            print("  => Placements DO transfer. Measuring under a probe name is sound, so any")
            print("     prediction error below comes from the bar changing, not from identity.")
        } else {
            print("  => Mixed. Treat prediction errors below as unexplained, not as evidence")
            print("     for either cause.")
        }

        // The link that turns a plausible story into a measured one.
        //
        // The claim being tested: a seam sent to a slot lands close enough to the map's
        // prediction that a FIXED 24pt tolerance rejected correct landings, because adjacent
        // slots are only ~35pt apart. Without this pass that was reasoning, not evidence.
        print("")
        print("LANDING vs PREDICTION  (what the old fixed 24pt tolerance judged)")
        var worstError: CGFloat = 0
        var wouldHaveInvalidated = 0
        for slot in restedSlots {
            let landedX = seam.reposition(placement: slot.placement,
                                          length: SpacerItem.restingLength)
            guard let landedX else {
                print("    pref \(slot.placement): could not be measured")
                continue
            }
            let error = abs(landedX - slot.landingX)
            worstError = max(worstError, error)
            let others = restedSlots.filter { $0.placement != slot.placement }.map(\.landingX)
            let nearestGap = others.map { abs($0 - slot.landingX) }.min() ?? 0
            let verdictOld = error > 24 ? "INVALIDATES (old)" : "ok (old)"
            if error > 24 { wouldHaveInvalidated += 1 }
            print("    pref \(slot.placement): predicted x\(Int(slot.landingX))"
                   + ", landed x\(Int(landedX))"
                   + ", error \(Int(error))pt"
                   + ", nearest slot \(Int(nearestGap))pt away"
                   + "  -> \(verdictOld)")
        }
        print("  worst error      : \(Int(worstError))pt")
        print("  old rule would have thrown the map away "
               + "\(wouldHaveInvalidated) of \(restedSlots.count) times")

        print("")
        print(String(repeating: "-", count: 68))
        print("COST: a cold measurement is \(String(format: "%.1f", restedCost))s;"
               + " a warm lookup is free.")
        print("  So what matters for a drag is how often the map is REBUILT, not what one")
        print("  measurement costs. Every invalidation buys another"
               + " \(String(format: "%.1f", restedCost))s.")
        print("")
        if expandedSlots.count == restedSlots.count {
            print("SEAM WIDTH: no effect. Both passes found"
                   + " \(restedSlots.count) slots, so an expanded seam does")
            print("  NOT prevent probes from landing, and resting before measuring is not")
            print("  what makes a measurement work. Anything claiming otherwise is wrong.")
        } else {
            print("SEAM WIDTH: it matters. Expanded found \(expandedSlots.count) slots,"
                   + " rested found \(restedSlots.count).")
            print("  A measurement taken while a seam is pushing is not trustworthy.")
        }

        seam.remove()
        exit(0)
    }
}
