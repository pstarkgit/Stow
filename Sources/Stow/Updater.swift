import AppKit
import Foundation

/// Self-updater: compares the installed build's commit against origin/main
/// of the source checkout, and can pull + rebuild + relaunch.
///
/// Model: the app is installed from a git checkout (SOURCE_DIR baked in at
/// install time). Updating means a git pull in that checkout plus ./install.sh,
/// which kills and relaunches the app.
///
/// Subprocesses run through `AsyncProcess.run`: fully async (readability
/// handlers plus a termination continuation), so no cooperative-pool thread is
/// ever blocked, no pipe is closed under an in-flight read, and a timeout
/// is a distinct outcome rather than a fake exit code.
///
/// Ported from AuthBar's `Updater`, which has already paid for this design
/// against a real self-update path. Stow carries the same states and the same
/// guards verbatim; only the plist keys and the process name change.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)          // last checked
        case available(String)       // short summary of newest commit
        case updating
        case failed(String)          // the update CHECK failed (transient)
        case installFailed(String)   // the INSTALL failed. Sticky: a fresh
                                     // check would re-derive .available (the
                                     // tree is still behind origin) and hide
                                     // the failure, so checks never clear it;
                                     // only an explicit user retry does.
        /// The bundle on disk no longer matches the running process: an install
        /// replaced it but the relaunch did not take. Distinct from .available
        /// because there is nothing left to fetch. The new build is already
        /// installed, it just is not the one executing.
        ///
        /// Without this state the app loops forever: `installedCommit` comes from
        /// the process's own loaded Info.plist, so a squashed-away stamp is not an
        /// ancestor of origin, every check re-derives .available, and every click
        /// reinstalls a bundle that is already there. Found live in AuthBar on
        /// 2026-08-14: process running an old build, bundle rewritten under it,
        /// update offered indefinitely. Stow carries the same guard from day one
        /// rather than waiting to rediscover the same bug.
        case restartRequired(String) // the commit sitting on disk
    }

    @Published var state: State = .idle

    /// Baked in by install.sh; empty in dev builds.
    static var sourceDir: String? {
        guard let dir = Bundle.main.infoDictionary?["STSourceDir"] as? String,
              !dir.isEmpty,
              FileManager.default.fileExists(atPath: dir + "/.git") else { return nil }
        return dir
    }

    static var installedCommit: String {
        Bundle.main.infoDictionary?["STCommit"] as? String ?? "dev"
    }

    /// The stamp in the bundle ON DISK, read fresh every time.
    ///
    /// `installedCommit` above comes from `Bundle.main`, which is loaded once at
    /// launch, so it reports the build that is EXECUTING. When an install
    /// replaces the bundle without a successful relaunch the two diverge, and
    /// only a fresh read of the plist on disk sees it. This is the comparison
    /// the design requires: the running stamp against a plist read from disk,
    /// never against the cached Bundle.main dictionary that the process loaded
    /// once at startup and will never see change again.
    static var onDiskCommit: String? {
        guard let path = Bundle.main.bundlePath as String?,
              let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let commit = plist["STCommit"] as? String,
              !commit.isEmpty else { return nil }
        return commit
    }

    var canUpdate: Bool { sourceDirProvider() != nil }
    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    var updateSummary: String? {
        if case .available(let summary) = state { return summary }
        return nil
    }

    var showsUpdateRow: Bool {
        switch state {
        case .available, .checking, .updating, .failed, .installFailed, .restartRequired:
            return true
        case .idle, .upToDate:
            return false
        }
    }

    /// Test seams: default to the real environment. Tests inject a temp
    /// checkout plus a fake installed stamp without touching Bundle.main.
    var sourceDirProvider: () -> String? = { Updater.sourceDir }
    var installedCommitProvider: () -> String = { Updater.installedCommit }
    /// nil means "cannot read the bundle", which is NOT staleness: an
    /// unreadable plist must not be reported as a pending restart.
    var onDiskCommitProvider: () -> String? = { Updater.onDiskCommit }

    /// One update-check decision, pure with respect to its inputs. Every
    /// git interaction flows through `git`, so tests can drive all branches
    /// against a real temp repository.
    static func decideCheck(
        installed: String,
        git: (_ args: [String]) async -> AsyncProcess.Outcome
    ) async -> State {
        // Bounded fetch: an auth-stalled fetch (an expired credential session, the
        // very state a bar manager cares about) must not wedge the updater.
        switch await git(["fetch", "--quiet", "origin", "main"]) {
        case .timedOut:
            return .failed("fetch timed out (network / auth?)")
        case .exited(let code, _, _) where code != 0:
            return .failed("fetch failed (network / auth?)")
        case .launchFailed:
            return .failed("git not available")
        case .exited:
            break
        }

        // One subprocess for both revs (independent lookups, batchable).
        guard case .exited(0, let revs, _) = await git(["rev-parse", "HEAD", "origin/main"]) else {
            return .failed("rev-parse failed")
        }
        let parts = revs.split(separator: "\n").map(String.init)
        guard parts.count == 2 else {
            return .failed("rev-parse failed")
        }
        let (local, remote) = (parts[0], parts[1])
        // Compare what's INSTALLED (Info.plist stamp), not just the checkout.
        // A dev checkout can be at or ahead of origin while the running binary
        // is stale (built before the last commits), and that IS an update.
        let installedIsCurrent: Bool
        if installed == "dev" {
            installedIsCurrent = true   // unstamped dev build, cannot compare
        } else if remote.hasPrefix(installed) {
            installedIsCurrent = true
        } else if case .exited(0, _, _) = await git(["merge-base", "--is-ancestor", remote, installed]) {
            installedIsCurrent = true   // installed at or past origin tip
        } else {
            installedIsCurrent = false
        }
        if installedIsCurrent, local == remote {
            return .upToDate(Date())
        }
        if !installedIsCurrent {
            // The BUILD is behind origin: offer the update even if the
            // checkout already has the commits (rebuild plus reinstall).
        } else {
            // Build current; checkout differs from origin. Only a REMOTE-
            // ahead state is an update. Local-ahead (unpushed commits)
            // must not offer a pointless pull plus reinstall loop.
            guard case .exited(0, _, _) = await git(["merge-base", "--is-ancestor", local, remote]) else {
                return .upToDate(Date())
            }
        }
        // What `.available` carries must stay a SINGLE LINE. Every consumer of
        // this payload is a one-line surface, so a multi-line log dump here would
        // corrupt every one of them at once. A count belongs here; the readable
        // prose belongs in CHANGELOG.md via the What's New pane. One home for
        // release notes.
        //
        // Base is the INSTALLED build when it is a usable rev, because that is
        // what the user is actually running. An unstamped dev build has nothing
        // to compare, so fall back to the checkout.
        let base = (installed != "dev" && installedIsCurrent == false) ? installed : local
        // The ancestry check is REQUIRED, not belt-and-braces. `A..B` is `^A B`,
        // which succeeds for any two KNOWN commits and only exits non-zero on an
        // unknown rev. Without this guard, a base left behind by a rebased
        // origin counts the rewritten duplicates too and reports an inflated "N
        // new builds" for an update the user will not actually receive as those
        // N commits.
        if case .exited(0, _, _) = await git(["merge-base", "--is-ancestor", base, remote]),
           case .exited(0, let out, _) = await git(["rev-list", "--count", "\(base)..\(remote)"]),
           let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            return .available("\(n) new build\(n == 1 ? "" : "s")")
        }
        // Unknown rev, or a base that is not an ancestor of origin (a rewritten
        // history), so no honest count exists. A noun phrase, not a sentence:
        // every consumer interpolates this into its own wording.
        return .available("a new build")
    }

    /// Checks origin for new commits. Cheap: one `git fetch` plus a rev compare.
    /// Never runs while an install is in flight: a periodic quiet check
    /// landing mid-install would clobber .updating and re-arm the button.
    func check(quiet: Bool = false) async {
        guard let dir = sourceDirProvider() else { return }
        if case .updating = state { return }
        // An install failure is sticky: the tree is still behind origin, so
        // any re-check would re-derive .available and silently replace the
        // failure with a fresh "Update" offer. Guarded BEFORE the .checking
        // transition, since that write is itself a clobber. performUpdate
        // accepts .installFailed directly so the user's retry lands on the
        // right action.
        if case .installFailed = state { return }
        // Staleness beats everything and costs one plist read. If the bundle on
        // disk is not the one running, no git answer is actionable: the new build
        // is already installed and the only remedy is a restart. Checked BEFORE
        // the .checking transition and before any subprocess, because the git
        // comparison uses the RUNNING stamp and would keep re-deriving
        // .available for a stamp that is no longer on disk.
        if let disk = onDiskCommitProvider(), disk != installedCommitProvider() {
            state = .restartRequired(disk)
            return
        }
        if !quiet { state = .checking }

        // Trims stdout so every consumer gets a clean value.
        func git(_ args: [String]) async -> AsyncProcess.Outcome {
            let outcome = await AsyncProcess.run(tool: "/usr/bin/git", arguments: ["-C", dir] + args,
                                                 timeout: 60)
            if case .exited(let code, let out, let err) = outcome {
                return .exited(code, out.trimmingCharacters(in: .whitespacesAndNewlines), err)
            }
            return outcome
        }

        let result = await Self.decideCheck(installed: installedCommitProvider(), git: git)
        // The install may have started while the check ran. Never
        // overwrite .updating with a stale check result.
        if case .updating = state { return }
        // Quiet (background) checks never surface transient failures, the same
        // behavior as before the decision core was extracted.
        if case .failed = result, quiet { return }
        state = result
    }

    /// Pulls and reinstalls. install.sh relaunches the app, so on success
    /// this process is replaced mid-flight and never observes the exit.
    /// The synchronous overload preserves the panel's fire-and-forget shape.
    func update() {
        Task { await performUpdate() }
    }

    /// Relaunches into the build sitting on disk.
    ///
    /// A process cannot exec its own replacement cleanly here, so a detached
    /// helper waits for this PID to disappear and then opens the bundle. `open`
    /// on a still-running app just activates the old instance, which is the exact
    /// failure this state exists to recover from, so waiting for exit is the
    /// whole point rather than a nicety.
    ///
    /// The wait is BOUNDED and the open is GUARDED on the process actually being
    /// gone. An unbounded waiter holding a deferred `open` is worse than a leak:
    /// if the quit does not complete, the orphan survives, and when the user
    /// later quits Stow deliberately it relaunches the app against their
    /// intent, once per Restart click.
    func restart() {
        let bundle = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Self.waiterScript, "--", String(pid), bundle]
        do {
            try p.run()
        } catch {
            // NEVER terminate without a relaunch pending. This app has no
            // window, so quitting with nothing to bring it back would make it
            // silently vanish with no icon and no explanation.
            state = .installFailed("could not launch the relaunch helper")
            return
        }
        NSApp.terminate(nil)
    }

    /// Poll for our exit, then open the bundle ONLY if we actually died.
    /// 300 polls at 0.2s is 60s, ample for a quit and short enough that a
    /// wedged main thread does not leave a permanent spinner.
    static let waiterScript = #"""
    n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt 300 ]; do
        sleep 0.2
        n=$((n+1))
    done
    kill -0 "$1" 2>/dev/null || open "$2"
    """#

    /// Awaitable install: callers that own a findings snapshot (the doctor)
    /// await this so they can refresh on the FAILURE path. On success the
    /// process is replaced and the continuation never resumes.
    func performUpdate() async {
        // .installFailed is a valid start: the update is still pending (the
        // tree never advanced), and Retry means retry the INSTALL.
        guard let dir = sourceDirProvider() else { return }
        switch state {
        case .available, .installFailed: break
        // .restartRequired must never reinstall: the build is already on disk
        // and the remedy is restart(). Explicit rather than falling into
        // `default`, so the intent is legible.
        case .restartRequired: return
        default: return
        }
        state = .updating
        // install.sh's OUTPUT IS REDIRECTED TO A FILE, not inherited through the
        // pipe, and that is load-bearing rather than tidiness.
        //
        // install.sh kills this app partway through (that is how a self-update
        // works), and Stow holds the only read ends of the child's pipes.
        // AsyncProcess resets signals to default in the child, so SIGPIPE kills
        // rather than being ignored: the moment the app dies, install.sh is
        // SIGPIPEd at its very next write.
        //
        // Every step between `rm -rf "$APP"` and the plist stamps is silent, so
        // the first write after the app dies is codesign's "replacing existing
        // signature", meaning the installer died leaving a bundle that was
        // replaced and stamped but NOT SIGNED. An unsigned bundle voids the
        // Accessibility grant the signing block exists to preserve, and Stow
        // cannot function at all without it (no reveal, no press, no bar scan).
        // Writing to a file the app does not own removes the pipe entirely, so
        // the installer's survival no longer depends on its parent.
        let log = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("stow-install.log")
        let outcome = await AsyncProcess.run(
            tool: "/bin/bash",
            arguments: ["-c",
                        #"cd "$1" && git pull --ff-only origin main && ./install.sh >"$2" 2>&1"#,
                        "--", dir, log],
            timeout: 600)
        switch outcome {
        case .launchFailed:
            state = .installFailed("could not launch installer")
        case .timedOut:
            state = .installFailed("update timed out")
        case .exited(let code, _, _) where code != 0:
            // The reason is in the log now, not on the pipe.
            state = .installFailed(Self.lastLine(ofLogAt: log) ?? "exit \(code)")
        case .exited:
            // install.sh normally kills this process before we get here.
            // If we're still alive (relaunch raced or was skipped), don't
            // stay wedged in .updating. Reset and re-verify.
            state = .idle
            await check(quiet: true)
        }
    }

    /// Last non-blank line of the installer log, for the failure message.
    ///
    /// `nonisolated`: a pure function of its argument, touching no instance state.
    nonisolated static func lastLine(ofLogAt path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// Fully async subprocess execution: drains stdout/stderr via readability
/// handlers (no blocked threads, no pipe-buffer deadlock), awaits real pipe
/// EOF (no grace-period race), and kills the whole process GROUP on timeout
/// so grandchildren (bash launching swift build) cannot orphan and hold the
/// pipes open.
enum AsyncProcess {
    enum Outcome {
        case exited(Int32, String, String)   // code, stdout, stderr
        case timedOut
        case launchFailed
    }

    /// Tail-bounded accumulator: consumers only ever use the last lines
    /// (error messages, rev hashes), so cap memory even if a build streams
    /// megabytes. Serial queue guards the single-producer handler callback.
    private final class Buf: @unchecked Sendable {
        private var data = Data()
        private let q = DispatchQueue(label: "asyncprocess.buf")
        private static let cap = 64 * 1024

        func append(_ d: Data) {
            q.sync {
                data.append(d)
                // Hysteresis: trim only past 2x cap, back down to cap. One
                // O(n) memmove per cap-worth of data instead of per append.
                if data.count > Self.cap * 2 {
                    data.removeFirst(data.count - Self.cap)
                }
            }
        }
        // Lossy decode: the tail-trim above can cut mid-UTF-8-sequence, and a
        // strict decode would nil out the ENTIRE buffer over one boundary byte.
        func string() -> String { q.sync { String(decoding: data, as: UTF8.self) } }
    }

    /// Installs a drain that appends until EOF, then self-clears and yields
    /// completion. The empty-read-means-EOF-means-self-clear rule lives ONLY here.
    private static func attachDrain(_ pipe: Pipe, into buf: Buf,
                                    onEOF: @escaping @Sendable () -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                onEOF()
            } else {
                buf.append(d)
            }
        }
    }

    static func run(tool: String, arguments: [String], timeout: TimeInterval) async -> Outcome {
        // Spawn via posix_spawn with POSIX_SPAWN_SETPGROUP (pgroup 0 means the
        // child leads a NEW process group whose id equals its own pid).
        // Foundation's Process does not do this, which makes killing
        // grandchildren (bash launching swift build) impossible: kill(-pid)
        // would target a nonexistent group and fall back to orphaning the
        // tree. Same pattern as PressActionProbe uses for its own subprocess work.
        let out = Pipe(), err = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&fileActions, err.fileHandleForWriting.fileDescriptor, 2)
        // Close the child's copies of the pipe fds at their ORIGINAL numbers
        // (the dup2'd 1/2 remain). Without this, every grandchild inherits an
        // extra write-end copy, delaying pipe EOF until the whole tree exits.
        // That is exactly the lingering-grandchild case the EOF bound below
        // defends against. Pipe fds are never 0/1/2 here, so the closes are safe.
        posix_spawn_file_actions_addclose(&fileActions, out.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&fileActions, err.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&fileActions, out.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&fileActions, err.fileHandleForReading.fileDescriptor)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // SETPGROUP(0): child leads a new process group (id equals its pid) so a
        // timeout can kill the whole tree. SETSIGMASK and SETSIGDEF: children
        // inherit the parent's signal mask, since a host that blocks SIGTERM
        // (test runners do) would otherwise produce children that ignore
        // the group kill.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        var allSigs = sigset_t()
        sigfillset(&allSigs)
        posix_spawnattr_setsigdefault(&attr, &allSigs)

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // System dirs FIRST: the updater script runs sudo, and a user-
        // writable /usr/local/bin or homebrew dir ahead of /usr/bin would
        // let a planted binary shadow git or sudo for a privileged flow.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:\(home)/.toolbox/bin"

        var pid: pid_t = 0
        let argv = ([tool] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let rc = posix_spawn(&pid, tool, &fileActions, &attr, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        // Parent must close its copies of the write ends or EOF never fires.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        guard rc == 0 else {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            return .launchFailed
        }

        let outBuf = Buf(), errBuf = Buf()
        // Separate streams: exit (single element) and per-pipe EOFs. Both
        // buffer yields, so events arriving before we await are not lost.
        let (exitStream, exitCont) = AsyncStream.makeStream(of: Int32.self)
        let (eofStream, eofCont) = AsyncStream.makeStream(of: Void.self)
        attachDrain(out, into: outBuf) { eofCont.yield() }
        attachDrain(err, into: errBuf) { eofCont.yield() }

        // Exit via kqueue (DispatchSourceProcess), no blocked thread.
        //
        // Declared as its own `let` and armed in a separate step, so the source
        // is never referenced from inside its own handler. AuthBar's original
        // wrote `exitSource.setEventHandler { ... exitSource.cancel() }`, a
        // strong self-capture that Swift 6's strict concurrency checker rejects:
        // the handler closes over the very source it is installed on, and
        // `setEventHandler` requires that closure to be safe to hand across an
        // arbitrary dispatch queue. Capturing `[weak exitSource]` removes the
        // self-reference entirely: the handler reads the source through a weak
        // slot rather than closing over the strong local binding, so there is
        // nothing self-referential left for the checker to flag, and the
        // handler degrades to a harmless no-op cancel in the vanishingly
        // unlikely case the source were already gone.
        let exitSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        exitSource.setEventHandler { [weak exitSource] in
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG)
            // reaped != pid (0 means not-yet-waitable, -1 means error): status is
            // garbage, so report a distinct failure code, not a fake clean 0.
            let code: Int32
            if reaped == pid {
                code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            } else {
                code = -1
            }
            exitCont.yield(code)
            exitCont.finish()
            exitSource?.cancel()
        }
        exitSource.resume()

        func cleanup() {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }

        // Phase 1: wait for EXIT racing the deadline. Completion keys off
        // exit, NOT pipe EOFs: an fd-inheriting grandchild must not turn
        // a successful run into a false timeout.
        let code: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                var it = exitStream.makeAsyncIterator()
                return await it.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }

        guard let code else {
            // Deadline hit: kill the GROUP. The child IS a group leader
            // (SETPGROUP above), so this reaches every descendant.
            kill(-pid, SIGTERM)
            cleanup()
            exitSource.cancel()
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                kill(-pid, SIGKILL)   // ESRCH once the group is gone, harmless.
                // Reap the group leader: exitSource was cancelled, so its
                // handler (the only other waitpid) will never fire. Without
                // this the child lingers as a zombie until the app exits.
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            }
            return .timedOut
        }

        // Phase 2: exit observed, collect the two pipe EOFs BEST-EFFORT
        // with a short bound. A grandchild holding a write-end open must
        // not stall us; Buf already holds everything written so far.
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var it = eofStream.makeAsyncIterator()
                for _ in 0..<2 where await it.next() != nil {}
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
            }
            defer { group.cancelAll() }
            return await group.next()
        }
        cleanup()
        return .exited(code, outBuf.string(), errBuf.string())
    }
}
