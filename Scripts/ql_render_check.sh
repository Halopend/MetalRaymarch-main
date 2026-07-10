#!/bin/bash
# Render regression gate for the Quick Look extension.
#
# Compiles the appex's EXACT Swift closure (derived from
# ThresholdQuickLook/wire_quicklook.rb so it can't drift) plus
# ThresholdQuickLook/Tests/RenderCheckMain.swift and a metallib built from
# Shaders.metal, then renders every bundled scene through the real
# HeadlessRenderer and asserts non-nil (all) + non-black (well-framed allowlist).
#
# Built -Onone so the RenderKitStubs assertionFailure guards are active — if the
# render path ever touches a stubbed app type, this run traps loudly.
#
# Usage:  bash Scripts/ql_render_check.sh
# Exit:   0 = all good, non-zero = a regression (render nil / unexpectedly black
#         / a stub was exercised / build failure).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Need a full Xcode (Metal toolchain + macOS SDK) — CommandLineTools lacks `metal`.
# Honor a caller-provided DEVELOPER_DIR; otherwise probe known Xcode locations.
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "$DEVELOPER_DIR" ]]; then
  for cand in \
    /Applications/Xcode-beta.app/Contents/Developer \
    /Applications/Xcode.app/Contents/Developer \
    "$(xcode-select -p 2>/dev/null)"; do
    if [[ -d "$cand" && -x "$cand/usr/bin/xcodebuild" ]]; then DEVELOPER_DIR="$cand"; break; fi
  done
fi
export DEVELOPER_DIR
echo "==> DEVELOPER_DIR=$DEVELOPER_DIR"

WIRE="$REPO/ThresholdQuickLook/wire_quicklook.rb"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> generating target-local embedded Metal source"
"$REPO/Scripts/generate_metal_embeds.sh" --output "$BUILD/EmbeddedMetalSources.swift"

echo "==> building metallib from Shaders.metal"
( cd "$REPO/Threshold" \
  && xcrun -sdk macosx metal -c Rendering/Shaders.metal -o "$BUILD/shaders.air" \
  && xcrun -sdk macosx metallib "$BUILD/shaders.air" -o "$BUILD/shaders.metallib" )

echo "==> deriving source closure from wire_quicklook.rb (SHARED_SOURCES only)"
# Scope to the SHARED_SOURCES array — the render closure. Deliberately EXCLUDE
# the per-extension EXTS[].sources (ThumbnailProvider/PreviewViewController/
# InteractiveFractalView), which pull in QuickLookThumbnailing/Quartz/Cocoa and
# aren't needed to exercise the render path.
FILES=()
while IFS= read -r p; do FILES+=("$REPO/$p"); done < <(
  awk 'f && /^\]/ {exit} /SHARED_SOURCES *= *\[/ {f=1} f' "$WIRE" \
    | grep -oE '"(Threshold|ThresholdQuickLook)/[^"]+\.swift"' | tr -d '"' | sort -u
)
FILES+=("$BUILD/EmbeddedMetalSources.swift")
FILES+=("$REPO/ThresholdQuickLook/Tests/RenderCheckMain.swift")
echo "    ${#FILES[@]} swift files"
[[ ${#FILES[@]} -ge 30 ]] || { echo "closure too small (${#FILES[@]}) — SHARED_SOURCES parse failed"; exit 2; }

echo "==> compiling render-check tool (-Onone, asserts active)"
xcrun -sdk macosx swiftc -Onone -g -target arm64-apple-macos26.0 \
  -import-objc-header "$REPO/Threshold/Rendering/ShaderTypes.h" \
  -framework Metal -framework MetalKit -framework ModelIO -framework AppKit \
  "${FILES[@]}" -o "$BUILD/render-check"

echo "==> rendering all bundled scenes"
cd "$REPO"
THRESHOLD_QL_METALLIB="$BUILD/shaders.metallib" "$BUILD/render-check" "Threshold/Examples/Scenes"
echo "==> render check PASSED"
