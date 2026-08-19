import SwiftUI

/// The What's New destination: release notes you can read ANY time, including
/// for the build you are already running.
///
/// Why this pane exists. Notes used to appear only inside the update row, as a
/// `git log` line like `d500886 fix the bar scan`, in AuthBar's earlier design.
/// Two problems: that is a commit subject, readable only if you know the
/// codebase, and it existed solely while an update was pending. The moment you
/// updated, there was nowhere to read what you had just installed.
///
/// Read-only, and it lives under STATUS rather than SETUP because it answers
/// "what is happening" rather than "how should this behave".
struct WhatsNewPane: View {
    @EnvironmentObject var updater: Updater

    /// Loaded once per appearance rather than per row: the file is small, but
    /// re-reading it inside a ForEach would hit disk on every redraw.
    ///
    /// The OUTCOME is kept, not just the entries, so an empty pane can name its
    /// actual cause instead of guessing one.
    @State private var outcome: ReleaseNotes.Outcome = .noCheckout

    /// The RUNNING version, compiled in, so the pane can mark your build even
    /// when no source checkout is present.
    private var installed: String { StowVersion.current }
    private var entries: [ReleaseNotes.Entry] { outcome.entries }
    private var pending: [ReleaseNotes.Entry] {
        ReleaseNotes.pending(afterVersion: installed, in: entries)
    }
    private var current: ReleaseNotes.Entry? {
        ReleaseNotes.entry(forVersion: installed, in: entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    // ALWAYS, not only when the list is empty. `parse` keeps the
                    // entries found before the fence, so the truncation case that
                    // actually loses data is the one WITH surviving entries: add a
                    // new entry at the top, break a fence below it, and everything
                    // under it disappears. Gating this on isEmpty made the warning
                    // unreachable in exactly that case.
                    if outcome.result.unterminatedFence, !entries.isEmpty {
                        fenceBanner
                    }
                    if entries.isEmpty {
                        empty
                    } else {
                        // Pending first: if something is waiting, that is what
                        // the reader came for.
                        if !pending.isEmpty {
                            sectionLabel("AVAILABLE IN THE NEXT UPDATE")
                            card {
                                ForEach(Array(pending.enumerated()), id: \.element.id) { i, e in
                                    if i > 0 { rowDivider }
                                    EntryRow(entry: e, running: false)
                                }
                            }
                        }
                        sectionLabel(pending.isEmpty ? "THIS BUILD" : "ALREADY INSTALLED")
                        card {
                            ForEach(Array(installedAndOlder.enumerated()), id: \.element.id) { i, e in
                                if i > 0 { rowDivider }
                                EntryRow(entry: e, running: e.id == current?.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .onAppear { outcome = ReleaseNotes.load(fromSourceDir: Updater.sourceDir) }
    }

    /// The running entry and everything older, NUMERICALLY.
    ///
    /// Delegates to `ReleaseNotes.installedAndOlder`, which is the tested complement
    /// of `pending`. A positional `dropFirst(pending.count)` is only correct for a
    /// file sorted newest-first, exactly the assumption this numeric comparison
    /// stops trusting.
    private var installedAndOlder: [ReleaseNotes.Entry] {
        ReleaseNotes.installedAndOlder(atOrBefore: installed, in: entries)
    }

    /// Shown above the list when a fence swallowed part of the file. Amber, the
    /// same attention colour the footer badge uses, because this is a "your file
    /// is losing content" state rather than an error the app can fix.
    private var fenceBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(StowTheme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ReleaseNotes.fileName) has an unclosed ``` fence.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(StowTheme.ink)
                Text("Entries after it were skipped, so this list is incomplete. Close the fence to see them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StowTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StowTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(StowTheme.orange.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(ReleaseNotes.fileName) has an unclosed fence. Entries after it were skipped, so this list is incomplete.")
    }

    /// App name and version as the identity, then a plain statement of update
    /// status, then the action that status implies.
    ///
    /// The version leads because it is the thing you came here to confirm. The
    /// status line says "you are up to date" in words rather than leaving you to
    /// infer it from the absence of a button, and "Check again" is offered here
    /// rather than only in the footer, so the pane can answer its own question.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Stow")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(StowTheme.ink)
                    Text(installed)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(StowTheme.hairline))
                        .foregroundStyle(StowTheme.inkSoft)
                }
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StowTheme.inkSoft)
            }
            Spacer(minLength: 0)
            headerAction
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// Says the state plainly, including the two states that are NOT "an update is
    /// available": already current, and installed-but-not-running.
    private var statusLine: String {
        switch updater.state {
        case .available(let summary):  return "\(summary) available."
        case .restartRequired(let disk): return "Build \(disk) is installed. Restart to use it."
        case .updating:                return "Installing an update\u{2026}"
        case .checking:                return "Checking for updates\u{2026}"
        case .installFailed(let why):  return "Last update failed: \(why)"
        case .failed:                  return "Could not check for updates."
        case .idle, .upToDate:
            return updater.canUpdate
                ? "You are up to date."
                : "Development build. Self-update is unavailable without a checkout."
        }
    }

    /// The action a given state should offer. Extracted as a pure function so the
    /// mapping is legible in one place. `.installFailed` is offered "Retry", not
    /// "Check again": `check()` early-returns on that state to stop a re-check
    /// silently replacing the failure with a fresh "Update" offer, so
    /// `performUpdate` accepts `.installFailed` directly and a retry is the
    /// action that actually recovers. Ported from AuthBar's `Updater.Action`,
    /// which learned this the hard way on a real CR review.
    enum Action: Equatable {
        case update         // start an available update
        case restart        // relaunch for an already-installed build
        case retry          // re-enter performUpdate after a failed install
        case progress       // work in flight, no button
        case recheck        // nothing to do but look again
        case none           // no checkout, so nothing is actionable
    }

    static func action(for state: Updater.State, canUpdate: Bool) -> Action {
        switch state {
        case .available:        return .update
        case .restartRequired:  return .restart
        case .installFailed:    return .retry
        case .checking, .updating: return .progress
        default:                return canUpdate ? .recheck : .none
        }
    }

    /// One action, matching the status: install, restart, retry, or re-check. Never two.
    @ViewBuilder
    private var headerAction: some View {
        switch Self.action(for: updater.state, canUpdate: updater.canUpdate) {
        case .update:
            headerButton("Update now", "arrow.down.circle.fill", prominent: true) {
                updater.update()
            }
        case .restart:
            headerButton("Restart", "arrow.clockwise.circle.fill", prominent: true) {
                updater.restart()
            }
        case .retry:
            headerButton("Retry", "arrow.clockwise.circle.fill", prominent: true) {
                updater.update()
            }
        case .progress:
            ProgressView().controlSize(.small)
        case .recheck:
            headerButton("Check again", "arrow.triangle.2.circlepath", prominent: false) {
                Task { await updater.check() }
            }
        case .none:
            EmptyView()
        }
    }

    private func headerButton(_ title: String, _ symbol: String,
                              prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(prominent ? AnyShapeStyle(StowTheme.sweep(for: .tidy))
                                  : AnyShapeStyle(StowTheme.card),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(prominent ? .white.opacity(0.16) : StowTheme.hairline))
            .foregroundStyle(prominent ? AnyShapeStyle(.primary)
                                       : AnyShapeStyle(StowTheme.inkSoft))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Names the ACTUAL cause. A branch on `sourceDir == nil` alone would let
    /// three different causes all render "no CHANGELOG.md in the source checkout
    /// yet, add one", false whenever the file existed and the wrong remedy on top
    /// of that. An unclosed ``` fence in particular would make a populated
    /// changelog report itself as absent.
    private var empty: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(emptyReason.headline)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(StowTheme.ink)
                Text(emptyReason.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StowTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private var emptyReason: (headline: String, detail: String) {
        switch outcome {
        case .noCheckout:
            return ("No source checkout, so release notes are unavailable.",
                    "Notes are read from the checkout this app was built from.")
        case .missing:
            return ("No \(ReleaseNotes.fileName) in the source checkout yet.",
                    "Add one and each entry appears here, newest first.")
        case .unreadable(_, let reason):
            return ("\(ReleaseNotes.fileName) could not be read.",
                    reason)
        case .parsed(let r) where r.unterminatedFence:
            return ("\(ReleaseNotes.fileName) has an unclosed ``` fence.",
                    "Everything after it was skipped. Close the fence and the entries reappear.")
        case .parsed:
            return ("\(ReleaseNotes.fileName) has no entries yet.",
                    "An entry starts with \"## \" followed by a commit, a date, and a headline.")
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(StowTheme.inkMuted)
            .padding(.top, 6)
    }

    private var rowDivider: some View {
        Rectangle().fill(StowTheme.hairline).frame(height: 1)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StowTheme.hairline))
    }
}

// MARK: - Row

/// One changelog entry: headline, date, and its changes as a list.
///
/// The running build is marked, because "which of these am I on" is the first
/// question a reader has and counting entries to work it out is a chore.
private struct EntryRow: View {
    let entry: ReleaseNotes.Entry
    let running: Bool

    /// The entry's own title, or nil when it has none.
    ///
    /// Nil rather than falling back to the version. Stow's `CHANGELOG.md` uses bare
    /// `## x.y.z` headings with no title after the number, so a version fallback
    /// rendered the SAME string twice per card: once in the chip beside it and again
    /// as the headline ("0.1.1  0.1.1  RUNNING"). AuthBar's changelog titles its
    /// releases, which is why the fallback looked harmless there.
    private var headline: String? {
        let title = entry.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != entry.version else { return nil }
        return title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The version as its own chip rather than inside the sentence: it is
                // a label, and monospacing keeps a column of them scannable.
                Text(entry.version)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(StowTheme.card, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(StowTheme.hairline))
                    .foregroundStyle(StowTheme.inkSoft)
                if let headline {
                    Text(EntryRow.styled(headline))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StowTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if running {
                    Text("RUNNING")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(StowTheme.sweep(for: .tidy),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1))
                }
                Spacer(minLength: 0)
                Text(entry.date)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(StowTheme.inkMuted)
            }
            ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // A drawn dot rather than a literal "-": the file's bullets
                    // are markdown syntax, not content to render.
                    Circle()
                        .fill(StowTheme.inkMuted)
                        .frame(width: 3, height: 3)
                        .padding(.top, 5)
                    // Markdown-rendered so **bold** and `code` in the file read
                    // as emphasis instead of showing their markers.
                    Text(EntryRow.styled(change))
                        .font(.system(size: 12))
                        .foregroundStyle(StowTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOverLabel)
    }

    /// The whole entry, including its changes.
    ///
    /// `.accessibilityElement(children: .combine)` merges the child Texts into a
    /// label, but an explicit `.accessibilityLabel` REPLACES that merge rather
    /// than adding to it. So naming only the headline and date left the entry's
    /// actual content silent, in a pane whose entire purpose is readable
    /// release notes. The changes are folded in explicitly, which is correct
    /// regardless of what the merge would have produced.
    ///
    /// Markdown is stripped via `styled`, because VoiceOver reads `**bold**` and
    /// backticks literally.
    private var voiceOverLabel: String {
        let plain = entry.changes
            .map { String(EntryRow.styled($0).characters) }
            .joined(separator: ". ")
        // Always leads with the version, since `headline` is nil for a bare
        // `## x.y.z` heading and VoiceOver would otherwise announce the date first
        // with no idea which release it belongs to.
        let name = headline.map { "\(entry.version), \($0)" } ?? entry.version
        let head = "\(name), \(entry.date)\(running ? ", currently running" : "")"
        return plain.isEmpty ? head : "\(head). \(plain)"
    }

    /// Inline markdown as an AttributedString, so `**bold**` and `` `code` ``
    /// from the file render as emphasis.
    ///
    /// Falls back to the raw text when parsing fails: showing the markers is
    /// ugly, but showing NOTHING because one entry has unbalanced backticks
    /// would be a blank pane.
    static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
