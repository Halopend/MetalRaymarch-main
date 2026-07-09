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
#   Scripts/build.sh embeds    # regenerate EmbeddedMetalSources.swift after any shader/header edit
#   Scripts/build.sh all       # embeds + mac + vision + test
#
# Override the toolchain explicitly:  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Scripts/build.sh mac

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="Threshold.xcodeproj"

# --- Toolchain selection -----------------------------------------------------
# Pin to the Xcode beta this project requires unless the caller overrides it.
# The beta has been installed under two names on different machines, so pick
# whichever actually exists rather than hard-coding one (verified 2026-07-07:
# only "Xcode-beta.app" is present here; the old "Xcode-beta 2.app" default was
# stale and made a fresh `build.sh` fail the existence check below).
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
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "ERROR: DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2
    echo "       Set DEVELOPER_DIR to your Xcode beta, e.g.:" >&2
    echo "       DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/build.sh $*" >&2
    exit 1
fi
echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"

COMMON_FLAGS=(-project "$PROJECT" -configuration Debug CODE_SIGNING_ALLOWED=NO)

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

build_mac()      { xcodebuild build "${COMMON_FLAGS[@]}" -scheme ThresholdMac  -destination 'platform=macOS'; }
build_vision()   { xcodebuild build "${COMMON_FLAGS[@]}" -scheme Threshold     -destination 'generic/platform=visionOS'; }
build_ios()      { xcodebuild build "${COMMON_FLAGS[@]}" -scheme ThresholdiOS  -destination 'generic/platform=iOS'; }
run_tests()      { xcodebuild clean test "${COMMON_FLAGS[@]}" "${TEST_FLAGS[@]}" -scheme ThresholdMac -destination 'platform=macOS'; }
run_tests_fast() { xcodebuild test       "${COMMON_FLAGS[@]}" "${TEST_FLAGS[@]}" -scheme ThresholdMac -destination 'platform=macOS'; }
regen_embeds()   { "$REPO_ROOT/Scripts/generate_metal_embeds.sh"; }
check_embeds()   { "$REPO_ROOT/Scripts/generate_metal_embeds.sh" --check; }

build_mac_checked()    { check_embeds; build_mac; }
build_vision_checked() { check_embeds; build_vision; }
build_ios_checked()    { check_embeds; build_ios; }
run_tests_checked()    { check_embeds; run_tests; }

case "${1:-mac}" in
    mac)      build_mac_checked ;;
    vision)   build_vision_checked ;;
    ios)      build_ios_checked ;;
    test)     run_tests_checked ;;
    testfast) run_tests_fast ;;
    embeds)   regen_embeds ;;
    all)      regen_embeds && build_mac && build_vision && run_tests ;;
    *) echo "Unknown command: $1 (expected: mac | vision | ios | test | testfast | embeds | all)" >&2; exit 2 ;;
esac
