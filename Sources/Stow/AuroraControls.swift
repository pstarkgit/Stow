import SwiftUI

/// Aurora form controls.
///
/// The Settings redesign (artifact ca6cc501 v5) named four specific defects in
/// the stock controls: a lavender toggle that matches nothing, a stepper whose
/// chevrons float away from their number, a number-plus-stepper for a value with
/// four sane options, and twin grey badges. These are the replacements, kept in
/// one file so every window uses the same paint rather than re-styling controls
/// at each call site.
///
/// `enum Aurora` (the well and raised surface tokens) is NOT declared here. Stow's
/// `Theme.swift` already owns it, since the token is a surface concept that the
/// whole app's chrome shares, not a control concept. Redeclaring it here would
/// collide with that definition, so every control below simply reaches for
/// `Aurora.inset` and gets Theme.swift's copy.
///
/// AuroraMenu and AuroraPicker are new to this file: AuthBar shipped five Aurora
/// controls but never a dropdown, so every menu in either app was still the stock
/// control. Stow needs one badly, so it is authored here and lands back in the
/// shared vocabulary for the next app in the family to pick up.

/// A segmented picker whose selected cell wears the Aurora gradient.
///
/// Replaces a number field plus stepper for values with a handful of sane
/// options: one tap instead of six clicks, and the legal range is visible rather
/// than discovered by hitting a clamp.
struct AuroraSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    /// Renders a value that is not in `options` as its own trailing segment.
    ///
    /// Without this the control silently narrows a legal range: a stored value
    /// outside the offered set highlights NOTHING, and the first tap overwrites
    /// it. Caught in review (CR-296399944) and it is not a corner case: the
    /// segments offer 4 of 24 legal `warnHours` values and 4 of 118 legal
    /// `armSeconds` values, so a config holding `warnHours: 6` or
    /// `armSeconds: 45` would render indeterminate and lose the value on touch.
    ///
    /// Same approach the polling and hotkey pickers already use: keep an extra
    /// tag for whatever is actually stored.
    var describeCustom: ((Value) -> String)? = nil

    /// The segments to draw: the declared options, plus the current value when it
    /// is not among them.
    private var displayed: [(value: Value, label: String)] {
        guard !options.contains(where: { $0.value == selection }) else { return options }
        guard let describe = describeCustom else { return options }
        return options + [(selection, describe(selection))]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(displayed.enumerated()), id: \.offset) { index, option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: isOn ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundStyle(isOn ? StowTheme.ink : StowTheme.inkSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isOn {
                                // A TINT of the gradient, not the full-strength
                                // sweep: at 22% it marks the selection without
                                // competing with Save, the window's one primary.
                                LinearGradient(colors: StowTheme.stops(for: .tidy)
                                                .map { $0.opacity(0.22) },
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)

                if index < displayed.count - 1 {
                    Rectangle()
                        .fill(StowTheme.hairline)
                        .frame(width: 1)
                }
            }
        }
        .background(Aurora.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StowTheme.hairline, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A stepper as ONE attached control: the value and its chevrons share a single
/// bordered capsule, chevrons stacked at the trailing edge.
///
/// The stock `Stepper` puts its chevrons in a separate control with its own
/// spacing, so the number and the buttons that change it read as two unrelated
/// widgets sitting near each other.
struct AuroraStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// How the number is rendered, "2h", "45 sec", whatever the row wants.
    let format: (Double) -> String
    var accessibilityName: String = "Value"

    var body: some View {
        HStack(spacing: 0) {
            Text(format(value))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(StowTheme.ink)
                .frame(minWidth: 58)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

            Rectangle().fill(StowTheme.hairline).frame(width: 1)

            VStack(spacing: 0) {
                chevron(up: true)
                Rectangle().fill(StowTheme.hairline).frame(height: 1)
                chevron(up: false)
            }
            .frame(width: 20)
        }
        .background(Aurora.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StowTheme.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: step)
            case .decrement: nudge(by: -step)
            @unknown default: break
            }
        }
    }

    private func chevron(up: Bool) -> some View {
        Button {
            nudge(by: up ? step : -step)
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(canNudge(up: up) ? StowTheme.inkSoft : StowTheme.inkMuted.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canNudge(up: up))
        .accessibilityHidden(true)   // the capsule itself is the adjustable element
    }

    private func canNudge(up: Bool) -> Bool {
        up ? value < range.upperBound : value > range.lowerBound
    }

    private func nudge(by delta: Double) {
        value = min(range.upperBound, max(range.lowerBound, value + delta))
    }
}

/// A monospaced capability badge, LOCAL, SSH, in its own hue.
///
/// The design's point: twin grey badges say nothing. Cyan for a local machine,
/// violet for one reached over ssh, so the badge carries information at a glance
/// rather than merely labelling.
struct AuroraBadge: View {
    let text: String
    let tint: Color

    static let local = Color(red: 0.133, green: 0.827, blue: 0.933)   // #22D3EE
    static let ssh   = Color(red: 0.655, green: 0.545, blue: 0.980)   // #A78BFA

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .kerning(1.0)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }
}

/// A live-watch indicator: a glowing dot marking that something is actively
/// being tracked right now, not merely configured.
///
/// Defaults to the `.tidy` state's own hue, so a live dot dropped into a row
/// without an explicit tint still reads as Stow's identity colour rather than a
/// borrowed one.
struct AuroraLiveDot: View {
    var tint: Color = StowTheme.stops(for: .tidy).first ?? .green

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .shadow(color: tint.opacity(0.7), radius: 3)
            .accessibilityHidden(true)
    }
}

/// An Aurora switch: ON is the lime-teal-indigo gradient with a soft glow, the
/// same paint as the panel's primary action. Replaces the stock lavender switch,
/// which matched nothing else in the app.
struct AuroraToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 10)
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn
                              ? AnyShapeStyle(StowTheme.sweep(for: .tidy))
                              : AnyShapeStyle(Aurora.inset))
                        .overlay(Capsule().strokeBorder(
                            configuration.isOn ? .white.opacity(0.18) : StowTheme.hairline,
                            lineWidth: 1))
                        .frame(width: 34, height: 20)
                        .shadow(color: configuration.isOn
                                ? StowTheme.edgeGlow(for: .tidy)
                                : .clear,
                                radius: 5)
                    Circle()
                        .fill(configuration.isOn ? Aurora.onGradient : StowTheme.inkSoft)
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.spring(duration: 0.22), value: configuration.isOn)
        }
    }
}

/// A dropdown whose trigger and rows wear the same paint as every other Aurora
/// control, built on SwiftUI's `Menu` rather than a hand-rolled popover.
///
/// Neither app had a styled dropdown before this: every menu was the stock blue
/// `Picker`/`Menu` chrome, dropped into an otherwise fully-themed window. Built
/// on `Menu` rather than a custom popover so keyboard navigation, type-ahead, and
/// VoiceOver all come from AppKit for free instead of being re-implemented here.
///
/// The closed trigger is where the "selected" state actually lives on screen, so
/// it is the trigger, not an individual row, that wears the tinted gradient: the
/// same 22% rule as `AuroraSegments`, for the same reason. A full-strength fill
/// on a dropdown that sits beside a Save button would read as a second primary
/// action, so the tint keeps it clearly secondary while still marking that a
/// choice has been made.
struct AuroraMenu<Value: Hashable>: View {
    let options: [(value: Value, label: String, shortcut: String?)]
    @Binding var selection: Value
    var placeholder: String = ""

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? placeholder
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    HStack {
                        Text(option.label)
                        if let shortcut = option.shortcut {
                            Spacer()
                            Text(shortcut)
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedLabel)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StowTheme.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StowTheme.inkSoft)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                // Same tint-not-fill rule as AuroraSegments: the gradient at 22%
                // marks that this control carries a live selection without
                // reading as the window's one primary action.
                LinearGradient(colors: StowTheme.stops(for: .tidy).map { $0.opacity(0.22) },
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
            .background(Aurora.inset)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StowTheme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A labelled settings row pairing a title with an `AuroraMenu`, for
/// Settings-style forms where every other row is label-left, control-right.
///
/// Exists because a bare `AuroraMenu` dropped straight into a form has no title,
/// so it does not read as a settings row until it is wrapped in the same
/// label-left layout every other row in the window already uses.
struct AuroraPicker<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(StowTheme.inkSoft)
            Spacer()
            AuroraMenu(options: options.map { (value: $0.value, label: $0.label, shortcut: nil) },
                       selection: $selection)
        }
    }
}
