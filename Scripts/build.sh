#!/usr/bin/env bash
# One-stop build/test wrapper for Threshold.
#
# WHY THIS EXISTS: the command-line `xcodebuild` default toolchain is frequently
# the WRONG Xcode for this project (it builds against an older SDK and fails or
# silently misbehaves). This project must build with the Xcode beta whose SDK
# matches the codebase. This script pins DEVELOPER_DIR so a fresh clone (or a
# future you) does not have to rediscover that trap, and bundles the
# CODE_SIGNING_ALLOWED=NO + destination flags every invocation needs.
#
# Usage:
#   Scripts/build.sh mac       # build ThresholdMac (all Swift + Metal) — fastest full compile check
#   Scripts/build.sh vision    # build the visionOS Threshold scheme (generic device)
#   Scripts/build.sh ios       # build the iOS scheme (generic device)
#   Scripts/build.sh test      # TRUSTWORTHY unit run: clean + serial (a green here is real)
#   Scripts/build.sh testfast  # fast incremental tests — ⚠️ can run STALE, don't trust a pass
#   Scripts/build.sh embeds    # generate an inspection copy under .build/Generated
#   Scripts/build.sh all       # embeds + mac + vision + test
#
# Override the toolchain explicitly:  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Scripts/build.sh mac

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="Threshold.xcodeproj"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    GIT_DIRTY=YES
else
    GIT_DIRTY=NO
fi

# --- Toolchain selection -----------------------------------------------------
# Prefer the local beta used during development, then fall back to the active
# Xcode selected by xcode-select. CI uses the latter because GitHub runner app
# names are versioned (for example, Xcode_26.5.app).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for candidate in \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode-beta 2.app/Contents/Developer"; do
        if [[ -d "$candidate" ]]; then
            DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
fi
export DEVELOPER_DIR

if [[ -z "$DEVELOPER_DIR" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "ERROR: no full Xcode developer directory was found: ${DEVELOPER_DIR:-<empty>}" >&2
    echo "       Select Xcode 26+ with xcode-select or set DEVELOPER_DIR explicitly." >&2
    exit 1
fi

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ ! "$SDK_MAJOR" =~ ^[0-9]+$ || "$SDK_MAJOR" -lt 26 ]]; then
    echo "ERROR: Threshold requires the macOS 26+ SDK; found $SDK_VERSION." >&2
    echo "       DEVELOPER_DIR=$DEVELOPER_DIR" >&2
    exit 1
fi
echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"
echo "Using macOS SDK $SDK_VERSION"

COMMON_FLAGS=(-project "$PROJECT" -configuration Debug CODE_SIGNING_ALLOWED=NO THRESHOLD_GIT_SHA="$GIT_SHA" THRESHOLD_GIT_DIRTY="$GIT_DIRTY")

# Why `test` is clean + serial (learned the hard way 2026-06-29):
#  • clean — the incremental builder has been observed to link ThresholdTests
#    against a STALE Threshold .swiftmodule (missing newly-added symbols, or an
#    outdated struct layout after a ShaderTypes.h / model field change). The test
#    bundle then runs old code and reports a false "TEST SUCCEEDED". `clean test`
#    forces the test target to recompile against the CURRENT module, so a pass
#    actually means the current code passed.
#  • -parallel-testing-enabled NO — the default spins up several MTLDevice test
#    hosts in parallel; under load they crash and sweep unrelated tests up as
#    phantom 0.000s "failures". Serial = one host = deterministic.
# Use `testfast` (incremental) only for tight iteration; re-confirm with `test`.
TEST_FLAGS=(-parallel-testing-enabled NO)
RESULT_FLAGS=()
if [[ -n "${THRESHOLD_RESULT_BUNDLE_PATH:-}" ]]; then
    RESULT_FLAGS=(-resultBundlePath "$THRESHOLD_RESULT_BUNDLE_PATH")
fi

build_mac()      { xcodebuild build "${COMMON_FLAGS[@]}" -scheme ThresholdMac  -destination 'platform=macOS'; }
build_vision()   { xcodebuild build "${COMMON_FLAGS[@]}" -scheme Threshold     -destination 'generic/platform=visionOS'; }
build_ios()      { xcodebuild build "${COMMON_FLAGS[@]}" -scheme ThresholdiOS  -destination 'generic/platform=iOS'; }
run_tests()      { xcodebuild clean test "${COMMON_FLAGS[@]}" "${TEST_FLAGS[@]}" "${RESULT_FLAGS[@]}" -scheme ThresholdMac -destination 'platform=macOS'; }
run_tests_fast() { xcodebuild test       "${COMMON_FLAGS[@]}" "${TEST_FLAGS[@]}" "${RESULT_FLAGS[@]}" -scheme ThresholdMac -destination 'platform=macOS'; }
regen_embeds()   { "$REPO_ROOT/Scripts/generate_metal_embeds.sh"; }

case "${1:-mac}" in
    mac)      build_mac ;;
    vision)   build_vision ;;
    ios)      build_ios ;;
    test)     run_tests ;;
    testfast) run_tests_fast ;;
    embeds)   regen_embeds ;;
    all)      regen_embeds && build_mac && build_vision && run_tests ;;
    *) echo "Unknown command: $1 (expected: mac | vision | ios | test | testfast | embeds | all)" >&2; exit 2 ;;
esac
