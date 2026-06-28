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
#   Scripts/build.sh test      # run the ThresholdTests unit suite on macOS
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
# (Confirmed-good as of 2026-06: "Xcode-beta 2.app" = 27.0.)
DEFAULT_DEVELOPER_DIR="/Applications/Xcode-beta 2.app/Contents/Developer"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "ERROR: DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2
    echo "       Set DEVELOPER_DIR to your Xcode beta, e.g.:" >&2
    echo "       DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Scripts/build.sh $*" >&2
    exit 1
fi
echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"

COMMON_FLAGS=(-project "$PROJECT" -configuration Debug CODE_SIGNING_ALLOWED=NO)

build_mac()    { xcodebuild build "${COMMON_FLAGS[@]}" -scheme ThresholdMac  -destination 'platform=macOS'; }
build_vision() { xcodebuild build "${COMMON_FLAGS[@]}" -scheme Threshold     -destination 'generic/platform=visionOS'; }
build_ios()    { xcodebuild build "${COMMON_FLAGS[@]}" -scheme ThresholdiOS  -destination 'generic/platform=iOS'; }
run_tests()    { xcodebuild test  "${COMMON_FLAGS[@]}" -scheme ThresholdMac  -destination 'platform=macOS'; }
regen_embeds() { "$REPO_ROOT/Scripts/generate_metal_embeds.sh"; }

case "${1:-mac}" in
    mac)    build_mac ;;
    vision) build_vision ;;
    ios)    build_ios ;;
    test)   run_tests ;;
    embeds) regen_embeds ;;
    all)    regen_embeds && build_mac && build_vision && run_tests ;;
    *) echo "Unknown command: $1 (expected: mac | vision | ios | test | embeds | all)" >&2; exit 2 ;;
esac
