import Foundation

/// Ordered semantic version, for comparing releases.
///
/// STRING comparison is wrong and quietly so: "0.2.9" is greater than "0.2.10"
/// under string ordering because '9' is greater than '1', which reverses the
/// moment a patch number reaches double digits. Components are compared
/// numerically, and a missing component counts as 0 so "0.2" equals "0.2.0".
///
/// Rejects anything that is not 2 or 3 all-numeric fields, so a prerelease tag or a
/// four-part build number is refused rather than silently mis-ordered.
///
/// `==` is implemented, NOT derived. A derived `==` compares the raw component
/// arrays, so "0.2" and "0.2.0" would be unequal while `<` correctly reports neither
/// is smaller. That breaks Comparable's contract (neither-less-nor-greater must mean
/// equal) and would let a Set hold both as distinct members. Caught by the test for
/// the zero-padding rule; the sibling type in Murmur derives `==` and has the same
/// latent inconsistency.
///
/// Ported from AuthBar and Murmur, which carry the same type and the same tests.
struct SemanticVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              fields.allSatisfy({ Int($0) != nil })
        else { return nil }
        components = fields.compactMap { Int($0) }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Human-readable release notes, parsed from `CHANGELOG.md`.
///
/// Why a file and not `git log`: AuthBar's update row used to render
/// `d500886 Ask macOS for the Input Monitoring state instead of inferring it`,
/// which is a commit subject with a SHA. That is engineering metadata, readable
/// only by someone who already knows the codebase, and it existed ONLY while an
/// update was pending, so after updating there was nowhere to read what
/// changed. Notes now live in a file written for the person running the app.
///
/// Entries are keyed to the VERSION, not the commit. A commit hash is an identity
/// only a developer can place, and keying on one meant the pane could not mark the
/// running build unless a source checkout was present. `StowVersion.current` is
/// compiled in, so the marking works from the bundle alone.
///
/// Shared with AuthBar and Murmur: this parser's shape and its hard-won rules,
/// skip fenced blocks, never split a heading on a bare hyphen, join wrapped
/// bullets, let a blank line end one. Do not fork those; all three apps were
/// bitten by them.
enum ReleaseNotes {

    /// One changelog entry.
    struct Entry: Equatable, Identifiable {
        /// Semantic version the entry describes. Also its identity.
        let version: String
        /// `YYYY-MM-DD`, as written. Kept as a string: it is displayed, never
        /// arithmetic, and parsing it would invent a timezone the file does not
        /// state.
        let date: String
        /// One-line headline for the entry.
        let title: String
        /// Body lines, already stripped of markdown bullets.
        let changes: [String]

        var id: String { version }
    }

    /// What a parse produced, plus whether the file was well-formed.
    ///
    /// `entries` alone cannot express "the file had content but a broken fence
    /// hid it", and that distinction is the difference between telling the user
    /// to write a changelog and telling them to close a fence.
    struct ParseResult: Equatable {
        let entries: [Entry]
        /// A ``` fence was opened and never closed, so everything after it was
        /// skipped. Entries parsed BEFORE the fence are still returned.
        let unterminatedFence: Bool

        static let empty = ParseResult(entries: [], unterminatedFence: false)
    }

    /// Why the pane has the entries it has, or why it has none.
    ///
    /// Each case is a cause the UI can state accurately. Collapsing them into
    /// `[]` is what let the pane report a false one.
    enum Outcome: Equatable {
        /// No source checkout, so there is nothing to read. Normal for a copy of
        /// the app installed without its repo.
        case noCheckout
        /// Checkout present, no CHANGELOG.md. Normal for a dev build.
        case missing(path: String)
        /// The file exists but could not be read (permissions, non-UTF-8 bytes).
        /// The only case with an actionable reason, so it carries one.
        case unreadable(path: String, reason: String)
        /// The file was read. May still hold zero entries.
        case parsed(ParseResult)

        var result: ParseResult {
            if case .parsed(let r) = self { return r }
            return .empty
        }

        var entries: [Entry] { result.entries }
    }

    /// Where the changelog lives, relative to the source checkout.
    static let fileName = "CHANGELOG.md"

    /// Parses a changelog into entries, newest first.
    ///
    /// Format, deliberately narrow so it cannot drift:
    /// ```
    /// ## <x.y.z> - <YYYY-MM-DD> - <headline>
    /// - a user-visible change
    /// - another
    /// ```
    /// Anything before the first `## ` is preamble and ignored, so the file can
    /// carry a title and a format note for whoever edits it.
    ///
    /// Lenient on purpose: a malformed heading is SKIPPED rather than failing the
    /// whole parse, because a typo in one entry must not blank the pane.
    ///
    /// Reports an unterminated fence rather than swallowing it. CommonMark treats
    /// an unclosed fence as running to end-of-file, so skipping the remainder is
    /// correct, but it silently DROPS entries, and one deleted backtick line in
    /// a hand-edited file previously turned a populated changelog into an empty
    /// pane reading "no CHANGELOG.md yet, add one" in AuthBar. The flag is what
    /// lets the UI name the real cause.
    static func parse(_ markdown: String) -> ParseResult {
        var entries: [Entry] = []
        var version: String?
        var date = ""
        var title = ""
        var changes: [String] = []

        func flush() {
            guard let v = version else { return }
            entries.append(Entry(version: v, date: date, title: title, changes: changes))
            version = nil; date = ""; title = ""; changes = []
        }

        // Fenced blocks are DOCUMENTATION, not entries. The file explains its own
        // format inside a ``` fence; parsing that yielded a fake "<headline>"
        // entry that the pane announced as a pending update.
        var inFence = false
        // A blank line ENDS a bullet, as it does in markdown. Without this,
        // prose following a blank line was appended to the previous bullet.
        var bulletOpen = false

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if line.isEmpty { bulletOpen = false; continue }
            if line.hasPrefix("## ") {
                flush()
                // Separator is an em dash or a SPACED hyphen. Never a bare
                // hyphen: splitting on the character shreds the ISO date
                // (2026-08-15 becomes "2026","08","15").
                //
                // Only the FIRST TWO separators are consumed, and the title is
                // kept verbatim. Splitting on every occurrence corrupted any
                // headline that itself contained the separator.
                let head = String(line.dropFirst(3))
                let sep = head.contains("\u{2014}") ? "\u{2014}" : " - "
                var fields: [String] = []
                var rest = Substring(head)
                while fields.count < 2, let r = rest.range(of: sep) {
                    fields.append(String(rest[rest.startIndex..<r.lowerBound]))
                    rest = rest[r.upperBound...]
                }
                fields.append(String(rest))
                let parts = fields
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard let ver = parts.first, !ver.isEmpty else { continue }
                version = ver
                date = parts.count > 1 ? parts[1] : ""
                title = parts.count > 2 ? parts[2] : ""
                bulletOpen = false
            } else if version != nil, line.hasPrefix("- ") || line.hasPrefix("* ") {
                changes.append(String(line.dropFirst(2)))
                bulletOpen = true
            } else if version != nil, bulletOpen, !changes.isEmpty {
                // A wrapped bullet continues on the next line. Without this the
                // tail of every hard-wrapped change was silently dropped. Only
                // while the bullet is still open: a blank line closed it.
                changes[changes.count - 1] += " " + line
            } else if version != nil, changes.isEmpty, title.isEmpty {
                // A prose line directly under a bare heading becomes the title,
                // so an entry without bullets still reads as something.
                title = line
            }
        }
        flush()
        return ParseResult(entries: entries, unterminatedFence: inFence)
    }

    /// Loads and parses the changelog, preferring the SOURCE CHECKOUT and falling
    /// back to the copy inside the bundle.
    ///
    /// The pane has two jobs, and only one source can serve both:
    ///
    ///   - "which entry am I running": either source answers this.
    ///   - "what would an update bring": ONLY the checkout can. `install.sh` refuses
    ///     unless the changelog's newest entry equals the version it stamps, and then
    ///     bundles that same file, so a bundled changelog's newest entry is always
    ///     the running version. Reading the bundle first made `pending` empty by
    ///     construction for every installed build, so the pending section could never
    ///     render at all.
    ///
    /// The bundled copy is therefore the FALLBACK, which is still the point of
    /// shipping it: a bundle whose checkout was moved or deleted keeps its release
    /// notes instead of showing "no source checkout, so release notes are
    /// unavailable". On an installed machine there is no source checkout at all
    /// (`install.sh` never lays one down), so this fallback is not an edge case
    /// for Stow, it is the ordinary path every installed user takes.
    ///
    /// `bundledPath` is the seam for the fallback branch. It is a PARAMETER rather
    /// than a mutable static because a static is shared process-global state: Swift
    /// Testing runs tests in parallel, so a test that pointed the seam at its own
    /// fixture changed what every concurrently executing sibling saw. A `defer`
    /// restore does not close that window, it only runs after the test finishes,
    /// while the race happens during it. As a parameter the state cannot be
    /// shared, so the race is unrepresentable rather than merely avoided by
    /// discipline.
    static func load(
        fromSourceDir dir: String?,
        bundledPath: () -> String? = { Bundle.main.path(forResource: "CHANGELOG", ofType: "md") }
    ) -> Outcome {
        if let dir {
            let path = (dir as NSString).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: path) { return read(path) }
        }
        if let bundled = bundledPath(), FileManager.default.fileExists(atPath: bundled) {
            return read(bundled)
        }
        guard let dir else { return .noCheckout }
        return .missing(path: (dir as NSString).appendingPathComponent(fileName))
    }

    private static func read(_ path: String) -> Outcome {
        do {
            return .parsed(parse(try String(contentsOfFile: path, encoding: .utf8)))
        } catch {
            // The one cause an operator can actually act on, so it keeps its reason
            // instead of being flattened away.
            return .unreadable(path: path, reason: error.localizedDescription)
        }
    }

    /// The entry describing the running build.
    ///
    /// Exact version match, not a prefix: versions are complete values, and prefix
    /// matching would make "0.1" claim to be the entry for "0.1.5".
    static func entry(forVersion version: String, in entries: [Entry]) -> Entry? {
        entries.first { $0.version == version }
    }

    /// Entries NEWER than the running version: what an update would bring.
    ///
    /// Compared NUMERICALLY, not by file order, so an out-of-order changelog cannot
    /// mislabel a release as pending. An entry whose version does not parse is
    /// skipped rather than guessed at.
    static func pending(afterVersion version: String, in entries: [Entry]) -> [Entry] {
        guard let mine = SemanticVersion(version) else { return [] }
        return entries.filter {
            guard let theirs = SemanticVersion($0.version) else { return false }
            return theirs > mine
        }
    }

    /// Entries at or OLDER than the running version, newest first. The complement of
    /// `pending`, so no entry can be silently dropped from both lists.
    static func installedAndOlder(atOrBefore version: String, in entries: [Entry]) -> [Entry] {
        guard let mine = SemanticVersion(version) else { return entries }
        return entries.filter {
            guard let theirs = SemanticVersion($0.version) else { return true }
            return theirs <= mine
        }
    }
}
