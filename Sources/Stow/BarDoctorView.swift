import SwiftUI
import AppKit

/// The Doctor window: Stow's diagnostic surface, ported from AuthBar's
/// `AuthDoctorView` (same hero-ring-plus-cards shape) but scoring Stow's own
/// findings instead of credential state.
///
/// Design section 10 is explicit about why this earns its place more than it did
/// in AuthBar: per-item press-action coverage is the one fact that decides how
/// often the expensive reveal dance runs, and nothing else in the app can show it.
struct BarDoctorView: View {
    /// True when hosted inside `MainWindow`'s sidebar. The window owns the frame,
    /// canvas and aurora edge in that case; drawing our own would double the glow,
    /// same rationale `AuthDoctorView.chromeless` documents.
    var chromeless: Bool = false

    /// Owned by `MainWindow` and shared with the sidebar badge, so the warning
    /// count is visible before this destination is ever opened. Passed in rather
    /// than created here, since two independently-created doctors would run their
    /// checks twice and could disagree with each other's findings.
    @ObservedObject var doctor: BarDoctor
    /// The display the picker at the top of `MainWindow` currently has selected.
    /// `checkPointMath` and `checkCoverage` both need it; `MainWindow` re-runs
    /// `doctor` whenever this changes, so this view only reads it for the manual
    /// refresh button below.
    let screen: NSScreen?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var headline: String {
        if doctor.anyRunning { return "Checking…" }
        if doctor.warnCount == 0 { return "Everything measurable looks healthy" }
        return doctor.warnCount == 1 ? "One thing needs you" : "\(doctor.warnCount) things need you"
    }
    private var subheadline: String {
        guard !doctor.findings.isEmpty else { return "Running Stow's own checks" }
        let when = doctor.lastRun.map { Fmt.agoShort($0) } ?? "just now"
        return "\(doctor.findings.count) checks · \(when)"
    }
    private var healthFraction: Double {
        let scored = doctor.passCount + doctor.warnCount
        return scored == 0 ? 0 : Double(doctor.passCount) / Double(scored)
    }

    /// Findings from a subsystem that exists today. Split from `planned` so the
    /// Doctor never implies a fix is one click away for a check that has nothing
    /// behind it yet.
    private var measured: [BarDoctor.Finding] {
        doctor.findings.filter { $0.id == "access" || $0.id == "pointmath" || $0.id == "coverage" }
    }
    /// Findings that report "not yet wired" because their subsystem is PLAN A.
    private var planned: [BarDoctor.Finding] {
        doctor.findings.filter { $0.id == "hotkey" || $0.id == "spacer" }
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !measured.isEmpty {
                        sectionView("MEASURED TODAY", findings: measured, offset: 0)
                    }
                    if !planned.isEmpty {
                        sectionView("PLAN A, NOT YET WIRED", findings: planned,
                                    offset: measured.count)
                    }
                    if doctor.findings.isEmpty && doctor.running {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small).tint(StowTheme.blue)
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    }
                }
                .padding(20)
            }
            footer
        }
        .frame(minWidth: chromeless ? nil : 500,
               idealWidth: chromeless ? nil : 560,
               maxWidth: chromeless ? .infinity : 760,
               minHeight: chromeless ? nil : 420,
               idealHeight: chromeless ? nil : 620,
               maxHeight: .infinity)
        .background {
            if !chromeless {
                ZStack {
                    StowTheme.canvas
                    RadialGradient(colors: [StowTheme.edgeGlow(for: .tidy).opacity(0.5), .clear],
                                   center: .init(x: 0.5, y: -0.1),
                                   startRadius: 10, endRadius: 420)
                }
                .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Bar Doctor")
        // Reveal on BOTH first appearance and later arrival, never on transition
        // alone.
        //
        // `onChange` fires only when the value actually changes, and `MainWindow`
        // starts `doctor.run` from a `.task` that usually finishes before this view
        // is on screen. In that ordering `findings.isEmpty` is ALREADY false at
        // first render, nothing ever changes it, `appeared` stays false, and every
        // finding row renders at `opacity(0)` while its section header stays
        // visible. The window then shows "5 checks" above a blank space, and the
        // hero ring stays unfilled because its trim is gated on the same flag.
        // Observed exactly that way before this was added.
        .onAppear { revealIfReady() }
        .onChange(of: doctor.findings.isEmpty) { _, _ in revealIfReady() }
    }

    /// Latches the reveal once findings exist. Idempotent, so calling it from both
    /// `onAppear` and `onChange` cannot double-animate.
    private func revealIfReady() {
        guard !doctor.findings.isEmpty, !appeared else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.5)) {
            appeared = true
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: appeared ? healthFraction : 0)
                    .stroke(doctor.warnCount > 0
                            ? AnyShapeStyle(StowTheme.sweep(for: .crowded))
                            : AnyShapeStyle(StowTheme.sweep(for: .tidy)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: doctor.warnCount > 0
                            ? StowTheme.edgeGlow(for: .crowded)
                            : StowTheme.edgeGlow(for: .tidy), radius: 9)
                    .animation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.15),
                               value: healthFraction)
                    .animation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.15),
                               value: appeared)
                if doctor.running && doctor.findings.isEmpty {
                    ProgressView().controlSize(.small).tint(StowTheme.blue)
                } else {
                    VStack(spacing: 0) {
                        Text("\(doctor.passCount)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(StowTheme.ink)
                        Text("of \(max(doctor.passCount + doctor.warnCount, 1))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StowTheme.inkMuted)
                    }
                }
            }
            .frame(width: 80, height: 80)
            .accessibilityLabel("\(doctor.passCount) of \(max(doctor.passCount + doctor.warnCount, 1)) scored checks passing")

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(StowTheme.ink)
                Text(subheadline)
                    .font(.system(size: 12))
                    .foregroundStyle(StowTheme.inkMuted)
            }
            Spacer()
            Button {
                Task { await doctor.run(screen: screen) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StowTheme.blue)
                    .frame(width: 34, height: 34)
                    .background(StowTheme.blue.opacity(0.13), in: Circle())
                    .overlay(Circle().strokeBorder(StowTheme.blue.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .disabled(doctor.running)
            .opacity(doctor.running ? 0.4 : 1)
            .help("Re-run all checks")
            .accessibilityLabel("Re-run all checks")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Sections

    private func sectionView(_ title: String, findings: [BarDoctor.Finding],
                             offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(StowTheme.sweep(for: .tidy))
                    .kerning(1.2)
                Rectangle()
                    .fill(StowTheme.hairline)
                    .frame(height: 1)
            }
            .padding(.leading, 4)
            VStack(spacing: 8) {
                ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                    BarFindingRow(finding: finding, perform: { perform($0) })
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(reduceMotion ? nil :
                                    .spring(duration: 0.45).delay(Double(offset + index) * 0.05),
                                   value: appeared)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Every measured finding has one action. The unwired ones have none, honestly.")
                .font(.system(size: 10))
                .foregroundStyle(StowTheme.inkMuted)
            Spacer()
            Text(StowVersion.builderAttribution)
                .font(.system(size: 10))
                .foregroundStyle(StowTheme.inkMuted)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(StowTheme.hairline),
                 alignment: .top)
    }

    private func perform(_ action: BarDoctor.Finding.Action) {
        switch action {
        case .grantAccessibility:
            PressActionProbe.requestTrust()
            Task { await doctor.run(screen: screen) }
        }
    }
}

// MARK: - Row

/// One diagnostic card, matching `AuthDoctorView`'s `FindingRow` shape: a glowing
/// icon tile, title plus detail, and either a quiet status word or the single
/// corrective action.
private struct BarFindingRow: View {
    let finding: BarDoctor.Finding
    let perform: (BarDoctor.Finding.Action) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 13) {
            iconTile
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StowTheme.ink)
                Text(finding.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(StowTheme.inkSoft)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(hovering ? StowTheme.cardHover : StowTheme.card,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(borderColor, lineWidth: 1))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.title): \(finding.detail)")
    }

    private var borderColor: Color {
        if case .warn = finding.status { return StowTheme.orange.opacity(0.35) }
        return StowTheme.hairline
    }

    /// The bar state this finding's status maps onto, so the tile wears the same
    /// gradient family the menu bar token does. `.info` (a planned check, or a
    /// measured one with nothing to warn about) has no natural `BarState` of its
    /// own, so it stays a flat ink tile rather than borrowing an unrelated hue.
    private var barState: BarState? {
        switch finding.status {
        case .pass:    return .tidy
        case .warn:    return .crowded
        case .running: return .arranging
        case .info:    return nil
        }
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(barState.map { AnyShapeStyle(StowTheme.diagonal(for: $0)) }
                  ?? AnyShapeStyle(Color.white.opacity(0.07)))
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: tileSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(barState == nil ? StowTheme.inkSoft : Aurora.onGradient)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: barState.map { StowTheme.edgeGlow(for: $0) } ?? .clear, radius: 5, y: 1)
    }

    private var tileSymbol: String {
        switch finding.id {
        case "access":    return "hand.raised.fill"
        case "pointmath": return "ruler.fill"
        case "coverage":  return "target"
        case "hotkey":    return "keyboard"
        case "spacer":    return "arrow.left.and.right"
        default:          return "checkmark.circle.fill"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch finding.status {
        case .pass:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StowTheme.stops(for: .tidy).first ?? StowTheme.blue)
        case .running:
            ProgressView().controlSize(.small).tint(StowTheme.blue)
        case .warn(let label):
            if let action = finding.action {
                actionButton(label, action: action)
            } else {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StowTheme.orange)
            }
        case .info(let label):
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(StowTheme.inkMuted)
        }
    }

    private func actionButton(_ label: String, action: BarDoctor.Finding.Action) -> some View {
        Button {
            perform(action)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Aurora.onGradient)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(StowTheme.sweep(for: .crowded), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

/// Minimal relative-time formatting, matching AuthBar's `Fmt.agoShort` closely
/// enough for the Doctor's subheadline. Stow carries no equivalent helper of its
/// own yet, and this file is the first thing in the module that needs one.
private enum Fmt {
    static func agoShort(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
