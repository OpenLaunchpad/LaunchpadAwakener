#!/usr/bin/env bash
# RunScript.sh — Build and launch LaunchpadAwakener with an arm64e daemon.
#
# Why this script exists: the daemon injects into the Dock, which is an arm64e
# process. Constructing the pointer-authenticated thread state that injection
# needs requires the injector itself to be arm64e, so the daemon must carry an
# arm64e slice.
#
# In the Xcode GUI this only works with the run destination set to "Any Mac".
# "My Mac" maps to -destination 'platform=macOS', which builds for the host and
# silently drops the arm64e slice, after which the daemon fails to link. This
# script always passes the generic destination.
#
# Usage:
#   ./RunScript.sh                     # build + launch
#   ./RunScript.sh --no-launch         # build only
#   ./RunScript.sh --scheme LaunchpadAwakenerStandalone   # build the standalone app; never launched here
#   ./RunScript.sh --update-packages   # refresh SPM pins first
#   ./RunScript.sh --clean             # wipe this script's DerivedData first
#   ./RunScript.sh --dry-run           # print commands without running
#   ./RunScript.sh --help
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

WORKSPACE="LaunchpadAwakener.xcworkspace"
SCHEME="LaunchpadAwakener"
CONFIGURATION="Debug"
PACKAGE_DIR="$PROJECT_DIR/LaunchpadAwakenerPackage"

# Keep SwiftPM checkouts out of the project tree so git clients do not index them.
# Falls back to a project-relative path when the dedicated volume is absent.
if [[ -d "/Volumes/DerivedData" ]]; then
    DERIVED_DATA="/Volumes/DerivedData/LaunchpadAwakener/arm64e"
else
    DERIVED_DATA="$PROJECT_DIR/DerivedData/arm64e"
fi

UPDATE_PACKAGES=false
CLEAN=false
LAUNCH=true
DRY_RUN=false

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[RunScript] $*"; }

# Prefer xcbeautify, fall back to xcsift, then to raw output — so a missing tool
# never blocks a build.
pretty() {
    if command -v xcbeautify >/dev/null 2>&1; then
        xcbeautify
    elif command -v xcsift >/dev/null 2>&1; then
        xcsift
    else
        cat
    fi
}

run() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; echo
    else
        "$@"
    fi
}

# Runs a command with output piped through pretty(), tee'ing the raw log so the
# full xcodebuild output stays recoverable when the formatter swallows a line.
run_piped() {
    if $DRY_RUN; then
        printf '+ '; printf '%q ' "$@"; printf '| tee <log> | pretty\n'
        return 0
    fi
    mkdir -p "$LOG_DIR"
    XCODEBUILD_LOG_INDEX=$((XCODEBUILD_LOG_INDEX + 1))
    local slug="${XCODEBUILD_LOG_NAME:-step}"
    local log_path
    log_path="$LOG_DIR/$(printf '%02d' "$XCODEBUILD_LOG_INDEX")-${slug}.log"
    log "Raw xcodebuild log: $log_path"
    "$@" 2>&1 | tee "$log_path" | pretty
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2;;
        --scheme) SCHEME="$2"; shift 2;;
        --configuration) CONFIGURATION="$2"; shift 2;;
        --derived-data) DERIVED_DATA="$2"; shift 2;;
        --update-packages) UPDATE_PACKAGES=true; shift;;
        --clean) CLEAN=true; shift;;
        --no-launch) LAUNCH=false; shift;;
        --dry-run) DRY_RUN=true; shift;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

[[ -d "$WORKSPACE" ]] || fail "workspace not found: $WORKSPACE"

LOG_DIR="${LOG_DIR:-$PROJECT_DIR/Products/Logs}"
XCODEBUILD_LOG_INDEX=0

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION"
log "derived_data=$DERIVED_DATA launch=$LAUNCH"

if $CLEAN; then
    log "Removing $DERIVED_DATA"
    run rm -rf "$DERIVED_DATA"
fi

if $UPDATE_PACKAGES; then
    log "Updating Swift package dependencies"
    run swift package update --package-path "$PACKAGE_DIR"
fi

# No ARCHS override is passed on purpose. Forcing ARCHS=arm64e on the command line applies to
# every target, including the SwiftMacro plugins this project depends on transitively
# (FrameworkToolboxMacros, SwiftStdlibToolboxMacros, FoundationToolboxMacros). Those are
# build-host tools; building them for arm64e leaves them absent from the products directory and
# every target that expands a macro then fails with:
#
#   Build input file cannot be found: '.../FrameworkToolboxMacros'
#
# (Measured: 81 errors, all from that one cause.)
#
# Getting an arm64e daemon takes five pieces working together, all of them already in the repo:
#
#   1. iOSPackagesShouldBuildARM64e = true in LaunchpadAwakener.xcworkspace's shared settings.
#      This must live in a real .xcworkspace — the one nested inside the .xcodeproj is ignored,
#      which is why this script builds -workspace rather than -project. The package must also be
#      a workspace member, so the .xcodeproj no longer carries its own folder reference to it.
#
#   2. ONLY_ACTIVE_ARCH = NO at the *project* level. The local Swift package is built with the
#      project's settings, so per-target settings never reach it, and Debug's default of YES trims
#      the arm64e slice right back off.
#
#   3. ENABLE_POINTER_AUTHENTICATION = YES on the daemon and payload targets — and ONLY there.
#      Raised to project level it also reaches the macro plugins, and the package's arm64e slice
#      then *replaces* arm64 instead of joining it, so those host-architecture plugins no longer
#      link. Correct looks like `MacroToolbox.o: x86_64 arm64 arm64e`; broken is a bare `arm64e`.
#
#   4. PrecompiledLibraries/swift-syntax — a local package named swift-syntax whose targets are
#      binaryTargets pointing at prebuilt xcframeworks. Being a workspace member, it overrides the
#      swift-syntax that FrameworkToolbox's macros would otherwise build from source. Without it,
#      those macro plugins fail to link against a swift-syntax built for a different slice.
#
#   5. -IDEEnableNewPackagePIFBuilder=NO below, which keeps Xcode 27 on its old package PIF
#      builder. The new one (Xcode 27's default) writes the arm64e package's ARCHS as the literal
#      `arm64 arm64e arm64e.x1`, where the old one writes `$(inherited) arm64e`. With x86_64 gone
#      from the package, every target that still compiles x86_64 fails with "Unable to resolve
#      module dependency" on the first package module it imports. The flag is a stopgap that keeps
#      the x86_64 slice for Intel Macs, which top out at macOS 26 — macOS 27 runs on Apple silicon
#      only. It reaches this script and nothing else: a build started from Xcode uses the new
#      builder and fails the same way. If a later Xcode ignores the flag or drops the old builder,
#      treat that as x86_64 being retired: delete the flag and set EXCLUDED_ARCHS = x86_64 at the
#      project level. Both injection paths use arm64 or arm64e only; the standalone app is the one
#      that loses Intel Macs.
#
# And the piece that is easiest to miss: the destination below must be
# `generic/platform=macOS`, not `platform=macOS`. The latter builds for *this machine* and
# collapses the build down to the host architecture, which silently discards the arm64e slice no
# matter what ARCHS and ONLY_ACTIVE_ARCH say. With the generic destination the package comes out
# `x86_64 arm64 arm64e` — arm64e appended rather than replacing arm64, which is exactly what keeps
# the macro plugins (host-architecture arm64) linkable at the same time.

log "Building"
XCODEBUILD_LOG_NAME="build" run_piped xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -IDEEnableNewPackagePIFBuilder=NO \
    -skipPackagePluginValidation -skipMacroValidation

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/$CONFIGURATION"
APP_PATH="$PRODUCTS_DIR/LaunchpadAwakener.app"

if $DRY_RUN; then
    log "Skipping verification and launch (--dry-run)"
    exit 0
fi

# --- The standalone app -------------------------------------------------------
#
# It injects nothing, so there is no daemon or payload to check for arm64e. And it is never launched
# here: opened, it covers the whole screen, which on a development machine is exactly what must not
# happen. It goes to a test machine instead.
if [[ "$SCHEME" == "LaunchpadAwakenerStandalone" ]]; then
    STANDALONE_APP_PATH="$PRODUCTS_DIR/Launchpad.app"
    [[ -d "$STANDALONE_APP_PATH" ]] || fail "expected $STANDALONE_APP_PATH"
    log "Built $STANDALONE_APP_PATH"
    log "Not launched: it covers the whole screen, so run it on a test machine only (see CLAUDE.md)."
    exit 0
fi

[[ -d "$APP_PATH" ]] || fail "expected $APP_PATH"

# --- Verify the slices that matter ------------------------------------------
#
# A build that silently produced an arm64-only daemon looks identical to a
# correct one until injection fails at runtime with an unhelpful error, so check
# here rather than discovering it later.

DAEMON_PATH="$(find "$APP_PATH/Contents/Library/LaunchServices" -type f -perm -u+x | head -1)"
PAYLOAD_PATH="$APP_PATH/Contents/Resources/LaunchpadAwakenerPayload.framework/LaunchpadAwakenerPayload"

verify_has_arm64e() {
    local label="$1" path="$2"
    [[ -f "$path" ]] || fail "$label not found at $path"
    local architectures
    architectures="$(lipo -info "$path" | sed 's/.*: //')"
    log "  $label: $architectures"
    [[ "$architectures" == *arm64e* ]] || fail "$label has no arm64e slice — injection into the Dock will fail"
}

log "Verifying architectures:"
verify_has_arm64e "daemon " "$DAEMON_PATH"
verify_has_arm64e "payload" "$PAYLOAD_PATH"

if $LAUNCH; then
    log "Launching $APP_PATH"
    run open "$APP_PATH"
else
    log "Launch skipped (--no-launch)"
fi

log "Done."
log "  app:          $APP_PATH"
log "  derived_data: $DERIVED_DATA"
log ""
log "Next: click Install, approve under System Settings > General > Login Items,"
log "then Inject Now. Watch the payload with:"
log "  log stream --predicate 'subsystem == \"com.MxIris.LaunchpadAwakener\"'"
