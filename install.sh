#!/bin/bash
# Builds Stow.app and installs it to /Applications.
#
# The transactional structure, the changelog gate, the stamp verification and the
# two-phase launch check are all carried over from AuthBar's install.sh. Every one of
# them exists because of a real failure; none is defensive padding. The privileged
# helper block is NOT carried over, because Stow needs no root daemon.
set -euo pipefail
cd "$(dirname "$0")"

# Running the whole script as root would read root's config and bake root's
# environment into the bundle. Check the effective uid, not just SUDO_UID, because
# `su` leaves that unset.
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: run ./install.sh as yourself, not as root" >&2
    exit 1
fi

swift build -c release

SRC_DIR="$(pwd)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
FINAL_APP=/Applications/Stow.app

# The VERSION comes from Swift, not from a literal here. StowVersion.current is the
# single source of truth precisely because the app has to be able to read it:
# Bundle.main returns nil under `swift run`, which is when a developer most needs to
# know which build is running. Stamping both plist keys FROM that one constant is
# also what keeps them equal.
VERSION_FILE="$SRC_DIR/Sources/Stow/StowVersion.swift"
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -1)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: could not read a numeric release version from $VERSION_FILE" >&2
    echo "       Expected a line of the form: static let current = \"x.y.z\"" >&2
    exit 1
fi

# The changelog's newest entry MUST describe the version being installed, so release
# notes cannot silently fall behind the code. Refusing here is the whole mechanism; a
# gate that only warns gets ignored.
#
# Two things this has to match the Swift parser on:
#   FENCES      the file documents its own format inside a ``` fence, and a gate with
#               no fence notion reads the EXAMPLE heading.
#   WHOLE FIELD capturing [0-9.]* truncates `## 0.1.0-rc1` to `0.1.0`, which MATCHES
#               and passes while the parser keeps the full string. Capture to
#               whitespace so a mismatch is loud.
CHANGELOG_HEAD="$(awk '
    /^```/ { fence = !fence; next }
    fence  { next }
    /^## / { print $2; exit }
' CHANGELOG.md)"
if [ "$CHANGELOG_HEAD" != "$VERSION" ]; then
    echo "ERROR: CHANGELOG.md's newest entry is '${CHANGELOG_HEAD:-none}', not $VERSION." >&2
    echo "       Add the entry for $VERSION before installing it." >&2
    exit 1
fi

# Called LATE, just before the swap, not here. Killing the app before the build means
# a signing failure leaves you with no running app AND no bundle.
#
# Stow has a specific reason to be careful: it owns the spacer item. If it dies with
# the spacer expanded and nothing brings it back, the user's tucked items stay off the
# bar with no way to recover them short of relaunching. Verifying the exit matters
# more here than it did for either sibling.
STOPPED_PIDS=""

stopped_instances_alive() {
    for pid in $STOPPED_PIDS; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

was_stopped_pid() {
    for pid in $STOPPED_PIDS; do
        [ "$pid" = "$1" ] && return 0
    done
    return 1
}

stop_running_instances() {
    # Capture ownership ONCE. Name-wide pgrep/pkill loops race short-lived CLI
    # diagnostics (`Stow --version`, `--rows`, `--probe`) and can briefly conclude
    # the app is gone while the original UI process still exists. Publication must
    # prove the exact process(es) present before the update are gone.
    STOPPED_PIDS="$(pgrep -x Stow || true)"
    [ -n "$STOPPED_PIDS" ] || return 0
    kill $STOPPED_PIDS 2>/dev/null || true
    for _ in $(seq 1 50); do
        stopped_instances_alive || break
        sleep 0.2
    done
    if stopped_instances_alive; then
        echo "  Stow ignored SIGTERM, sending SIGKILL"
        for pid in $STOPPED_PIDS; do
            kill -9 "$pid" 2>/dev/null || true
        done
        for _ in $(seq 1 25); do
            stopped_instances_alive || break
            sleep 0.2
        done
    fi
    if stopped_instances_alive; then
        echo "ERROR: Stow survived SIGKILL; refusing to replace its bundle. Quit Stow and re-run." >&2
        return 1
    fi
}

stop_legacy_rail() {
    pgrep -x Rail >/dev/null || return 0
    echo "Stopping legacy Rail so two menu bar managers do not compete"
    pkill -x Rail 2>/dev/null || true
    for _ in $(seq 1 25); do
        pgrep -x Rail >/dev/null || return 0
        sleep 0.2
    done
    echo "ERROR: Rail is still running. Quit it before installing Stow." >&2
    return 1
}

stop_legacy_airlock() {
    pgrep -x Airlock >/dev/null || return 0
    echo "Stopping Airlock so two menu bar managers do not compete"
    pkill -x Airlock 2>/dev/null || true
    for _ in $(seq 1 25); do
        pgrep -x Airlock >/dev/null || return 0
        sleep 0.2
    done
    echo "ERROR: Airlock is still running. Quit it before installing Stow." >&2
    return 1
}

# TRANSACTIONAL INSTALL. The replacement is built in a private staging directory and
# only swapped in once it is complete and signed. A failure before the swap leaves the
# working app untouched; a failure after it restores the previous bundle.

# Reclaim anything a SIGKILLed run left behind. The EXIT trap handles every signal it
# can catch, but SIGKILL is uncatchable: a kill between the two renames strands the
# previous bundle inside an orphaned stage with NO app installed. Restore FIRST,
# delete second, because a backup that is still needed must not be pruned as garbage.
for orphan in "$(dirname "$FINAL_APP")"/.stow-install.*; do
    [ -d "$orphan" ] || continue
    if [ ! -d "$FINAL_APP" ] && [ -d "$orphan/Stow.app.previous" ]; then
        if mv "$orphan/Stow.app.previous" "$FINAL_APP"; then
            echo "Recovered Stow.app from an interrupted install ($orphan)"
        fi
    fi
    rm -rf "$orphan"
done

# The stage lives NEXT TO the destination, not in $TMPDIR. `mv` is an atomic rename
# only within one filesystem; across filesystems it degrades to copy-then-delete,
# which reintroduces the half-replaced-bundle window this design removes.
STAGE_ROOT="$(mktemp -d "$(dirname "$FINAL_APP")/.stow-install.XXXXXX")"
BACKUP_APP="$STAGE_ROOT/Stow.app.previous"
STAGE_APP="$STAGE_ROOT/Stow.app"

cleanup_stage() {
    # Restore before pruning whenever the destination is missing. The swap is two
    # renames, and a kill between them would otherwise let this trap delete the
    # backup and leave nothing installed.
    if [ ! -d "$FINAL_APP" ] && [ -d "$BACKUP_APP" ]; then
        mv "$BACKUP_APP" "$FINAL_APP" 2>/dev/null \
            && echo "Restored the previous Stow.app after an interrupted install" >&2
    fi
    rm -rf "$STAGE_ROOT"
}
trap cleanup_stage EXIT

APP="$STAGE_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stow "$APP/Contents/MacOS/Stow"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Release notes ship INSIDE the bundle, so What's New works for a copy whose source
# checkout was moved or deleted.
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>Stow</string>
    <key>CFBundleIdentifier</key>      <string>dev.starkpat.stow</string>
    <key>CFBundleName</key>            <string>Stow</string>
    <key>CFBundleDisplayName</key>     <string>Stow</string>
    <!-- Placeholders deliberately NOT a legal version: the verification below
         compares against $VERSION, and a placeholder like "1.0" is itself legal, so
         at VERSION=1.0 the check would approve a wholly unstamped plist. -->
    <key>CFBundleVersion</key>         <string>UNSTAMPED</string>
    <key>CFBundleShortVersionString</key> <string>UNSTAMPED</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>    <false/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>STSourceDir</key>             <string></string>
    <key>STCommit</key>                <string></string>
    <key>STBuildDate</key>             <string></string>
</dict>
</plist>
PLIST

# Stamp via PlistBuddy: literal assignment, no sed metacharacter hazards. A & \ or |
# in a clone path would corrupt the plist and break self-update.
/usr/libexec/PlistBuddy \
    -c "Set :STSourceDir \"$SRC_DIR\"" \
    -c "Set :STCommit \"$COMMIT\"" \
    -c "Set :STBuildDate \"$BUILD_DATE\"" \
    -c "Set :CFBundleVersion \"$VERSION\"" \
    -c "Set :CFBundleShortVersionString \"$VERSION\"" \
    "$APP/Contents/Info.plist"

# Verify the stamps round-trip. A silently wrong source dir breaks self-update for
# every install from this clone, and a version that failed to stamp is how AuthBar
# shipped "1.0" on its first run.
stamped="$(/usr/libexec/PlistBuddy -c "Print :STSourceDir" "$APP/Contents/Info.plist")"
if [ "$stamped" != "$SRC_DIR" ]; then
    echo "ERROR: Info.plist stamp mismatch: '$stamped' != '$SRC_DIR'" >&2
    exit 1
fi
for key in CFBundleShortVersionString CFBundleVersion; do
    stamped="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")"
    if [ "$stamped" != "$VERSION" ]; then
        echo "ERROR: $key is '$stamped', expected '$VERSION'" >&2
        exit 1
    fi
done

# --- Signing -----------------------------------------------------------------
#
# A STABLE identity matters MORE for Stow than for either sibling. Accessibility is
# the only TCC grant Stow has, and the entire reveal mechanism is dead without it.
# An ad-hoc signature changes on every build, which voids the grant every install and
# means re-granting in System Settings each time.
DEVID="Developer ID Application: Patrick Stark (P2M5LH6CVA)"
LOCAL_IDENTITY="Stow Dev"
# Captured ONCE rather than piped into `grep -q` twice. Under pipefail, `grep -q`
# exits on first match and closes the pipe; a writer with buffered output dies of
# SIGPIPE and pipefail reports the pipeline as failed, so a Developer ID that IS
# present would read as absent and silently drop to ad-hoc.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
case "$IDENTITIES" in *"$DEVID"*) HAVE_DEVID=1 ;; *) HAVE_DEVID=0 ;; esac
case "$IDENTITIES" in *"$LOCAL_IDENTITY"*) HAVE_LOCAL=1 ;; *) HAVE_LOCAL=0 ;; esac

if [ "$HAVE_DEVID" -eq 1 ]; then
    SIGN_OPTS=(--force --options runtime)
    # The timestamp is a synchronous round trip to Apple. Opt-in, because this script
    # is what the in-app updater runs non-interactively, and under `set -e` a
    # timestamp-server outage would abort the update with no terminal to show why.
    if [ "${STOW_TIMESTAMP:-0}" = "1" ]; then
        SIGN_OPTS+=(--timestamp)
    else
        SIGN_OPTS+=(--timestamp=none)   # explicit; codesign contacts the server otherwise
    fi
    codesign "${SIGN_OPTS[@]}" --sign "$DEVID" "$APP"
    echo "Signed with Developer ID + Hardened Runtime"
elif [ "$HAVE_LOCAL" -eq 1 ]; then
    codesign --force --deep --sign "$LOCAL_IDENTITY" "$APP"
    echo "Signed with local identity: $LOCAL_IDENTITY (this Mac only; TCC grants persist)"
else
    codesign --force --deep --sign - "$APP"
    echo "WARNING: ad-hoc signed. Accessibility must be RE-GRANTED after every"
    echo "         install, and Stow cannot reveal anything without it. Create a"
    echo "         self-signed '$LOCAL_IDENTITY' code-signing identity in Keychain"
    echo "         Access once to make the grant stick."
fi

# Do not publish a bundle whose CMS signature cannot build a trusted chain on
# this Mac. `codesign` can successfully write a signature while a missing or
# stale intermediate still makes the result unverifiable.
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "ERROR: the staged Stow.app signature did not verify; live app unchanged." >&2
    exit 1
fi

# --- Publication: the only point where the live app is touched ----------------
stop_legacy_airlock || exit 1
stop_legacy_rail || exit 1
stop_running_instances || exit 1

restore_backup() {
    [ -d "$BACKUP_APP" ] || return 1
    # `|| true`: under set -e an undeletable file would abort before the mv, leaving a
    # partial bundle at the destination. The trap then sees a present destination,
    # skips its restore, and removes the stage, destroying the only remaining copy.
    rm -rf "$FINAL_APP" || true
    if [ -e "$FINAL_APP" ]; then
        rescued="${FINAL_APP}.previous"
        rm -rf "$rescued" || true
        if mv "$BACKUP_APP" "$rescued" 2>/dev/null; then
            echo "ERROR: could not clear $FINAL_APP." >&2
            echo "       The previous app is at $rescued -- move it back manually." >&2
        else
            echo "ERROR: could not clear $FINAL_APP, and the previous app is stuck at" >&2
            echo "       $BACKUP_APP and will be removed on exit. Copy it NOW." >&2
        fi
        return 1
    fi
    mv "$BACKUP_APP" "$FINAL_APP" || return 1
    echo "Restored the previous Stow.app" >&2
    open -n "$FINAL_APP" 2>/dev/null || true
}

HAD_PREVIOUS=false
if [ -d "$FINAL_APP" ]; then
    if ! mv "$FINAL_APP" "$BACKUP_APP"; then
        # NOT "nothing was changed": the app was stopped above, so it is down.
        echo "ERROR: could not move the existing app aside; it is unchanged but stopped." >&2
        open -n "$FINAL_APP" 2>/dev/null || true
        exit 1
    fi
    HAD_PREVIOUS=true
fi

if ! mv "$STAGE_APP" "$FINAL_APP"; then
    echo "ERROR: could not move the new app into place." >&2
    [ "$HAD_PREVIOUS" = true ] && restore_backup
    exit 1
fi

# Force a NEW Launch Services instance. The old process is gone by this point, but
# Launch Services can retain its registration briefly after an in-app update. Plain
# `open` then returns success after targeting that dead registration and starts
# nothing; the health check waits ten seconds, reports "never started", and rolls a
# valid signed update back. `-n` bypasses that stale registration. The verified
# pgrep shutdown above prevents this from creating a duplicate live instance.
if ! open -n "$FINAL_APP"; then
    echo "ERROR: the new Stow.app could not be launched." >&2
    [ "$HAD_PREVIOUS" = true ] && restore_backup
    exit 1
fi

# `open` succeeding only means launchd accepted the bundle. One that crashes on
# startup exits within a second or two, and without this the installer would report
# success over a broken app.
#
# Two phases, because "has not started yet" and "started and died" are different
# states a single loop conflates. Registration after `open` is asynchronous: AuthBar
# measured 0.12-0.17s warm, against a first sample at 0.2s, so a cold machine would
# miss the first sample and roll a HEALTHY install back.
NEW_PID=""
for _ in $(seq 1 50); do
    for candidate in $(pgrep -x Stow || true); do
        if ! was_stopped_pid "$candidate"; then
            NEW_PID="$candidate"
            break
        fi
    done
    [ -n "$NEW_PID" ] && break
    sleep 0.2
done

# Only once a distinct replacement PID exists does absence mean death. EVERY sample
# must then find THAT SAME PID alive. A name-wide pgrep can be satisfied by the old
# process, a CLI diagnostic, or a later respawn and falsely approve the installation.
STAYED_RUNNING=false
if [ -n "$NEW_PID" ]; then
    STAYED_RUNNING=true
    for _ in $(seq 1 25); do
        sleep 0.2
        if ! kill -0 "$NEW_PID" 2>/dev/null; then STAYED_RUNNING=false; break; fi
    done
fi
if [ "$STAYED_RUNNING" != true ]; then
    if [ -n "$NEW_PID" ]; then
        echo "ERROR: the new Stow.app started, then exited." >&2
    else
        echo "ERROR: the new Stow.app never started." >&2
    fi
    [ "$HAD_PREVIOUS" = true ] && restore_backup
    exit 1
fi

echo "Installed and relaunched $FINAL_APP (version $VERSION, build $COMMIT)"
echo
echo "NEXT: close the design's hard gate before building any UI."
echo "  /Applications/Stow.app/Contents/MacOS/Stow --probe"
