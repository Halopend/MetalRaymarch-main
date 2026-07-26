#!/usr/bin/env bash
# Mac perf regression gate for the raymarch renderer.
#
# Runs the headless benchmark harness (THRESHOLD_BENCHMARK=1, hermetic — it
# ignores and never touches the user's persisted settings) on the canonical
# "Stress test" scene at 1080p in two configs:
#
#   accel-on   the acceleration levers a real install runs with (cone march,
#              distance LOD, over-relaxation, bounding-sphere skip) — ~19.6 ms
#   accel-off  raw march at code defaults — ~52 ms, exercises the unaccelerated
#              path the levers hide
#
# and fails if either config's gpuMsAvg regresses more than TOLERANCE_PCT vs
# the checked-in baseline, if the measured steps-to-converge drift (behavior
# change), or if the captured PNG is not byte-identical to the baseline PNG
# (visual change — captures are phase-deterministic, so identical is the
# expectation, not a stretch goal).
#
# Usage:
#   Scripts/perf-gate.sh               # build + gate
#   PERF_GATE_SKIP_BUILD=1 Scripts/perf-gate.sh
#   Scripts/perf-gate.sh --rebaseline  # accept current numbers as the new baseline
#
# Exit: 0 = pass, 1 = regression, 2 = harness/infra failure.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TOLERANCE_PCT="${PERF_GATE_TOLERANCE_PCT:-5}"
STEPS_TOLERANCE_PCT="${PERF_GATE_STEPS_TOLERANCE_PCT:-2}"
SCENE="Stress test"
SIZE="1920x1080"
ACCEL_QC="coneMarchStrength=1,distanceLODStrength=0.98,overRelaxationMax=1.6,boundingSphereSkipEnabled=1"
BASE="$REPO/Baselines"
REBASELINE=0
[[ "${1:-}" == "--rebaseline" ]] && REBASELINE=1

if [[ "${PERF_GATE_SKIP_BUILD:-0}" != "1" ]]; then
    echo "==> building ThresholdMac"
    Scripts/build.sh mac >/dev/null
fi

# Resolve THIS repo's app. build.sh pins -derivedDataPath to the repo-local
# .build/DerivedData (THRESHOLD_DERIVED_DATA_PATH overrides), so that product is
# authoritative — a global-DerivedData scan here could silently pick up a STALE
# app built before the pin. Fall back to the legacy WorkspacePath scan only for
# trees never built via build.sh (e.g. Xcode-GUI-only checkouts).
APP=""
LOCAL_APP="${THRESHOLD_DERIVED_DATA_PATH:-$REPO/.build/DerivedData}/Build/Products/Debug/Threshold.app"
if [[ -x "$LOCAL_APP/Contents/MacOS/Threshold" ]]; then
    APP="$LOCAL_APP"
else
    for dd in "$HOME"/Library/Developer/Xcode/DerivedData/Threshold-*; do
        wp="$(defaults read "$dd/info" WorkspacePath 2>/dev/null || true)"
        if [[ "$wp" == "$REPO/Threshold.xcodeproj" ]]; then
            APP="$dd/Build/Products/Debug/Threshold.app"
            break
        fi
    done
fi
[[ -n "$APP" && -x "$APP/Contents/MacOS/Threshold" ]] \
    || { echo "FATAL: no built Threshold.app for $REPO (run without PERF_GATE_SKIP_BUILD)" >&2; exit 2; }
echo "==> app: $APP"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hermetic preset store: the canonical scene lives in Baselines/scenes/ (it is
# NOT a bundled preset, and the user's live store may be iCloud-mode, which an
# unsigned debug build cannot resolve). Stage it into a temp store root and
# point the app there via THRESHOLD_BENCHMARK_STORE_ROOT.
mkdir -p "$WORK/store/Scenes"
cp "$REPO/Baselines/scenes/"*.threshscene "$WORK/store/Scenes/"

run_config() { # $1=name  $2=qc-override ("" for none)
    local name="$1" qc="$2"
    mkdir -p "$WORK/png-$name"
    echo "==> running $name"
    env THRESHOLD_BENCHMARK=1 \
        THRESHOLD_BENCHMARK_STORE_ROOT="$WORK/store" \
        THRESHOLD_BENCHMARK_SCENES="$SCENE" \
        THRESHOLD_BENCHMARK_SHADOWS=1 \
        THRESHOLD_BENCHMARK_SIZE="$SIZE" \
        ${qc:+THRESHOLD_BENCHMARK_QC="$qc"} \
        THRESHOLD_BENCHMARK_OUT="$WORK/$name.json" \
        THRESHOLD_BENCHMARK_PNG_DIR="$WORK/png-$name" \
        "$APP/Contents/MacOS/Threshold" 2>&1 | grep "🏁" | sed 's/^/    /' || true
    [[ -f "$WORK/$name.json" ]] || { echo "FATAL: $name produced no JSON" >&2; exit 2; }
    [[ -f "$WORK/png-$name/$SCENE.png" ]] || { echo "FATAL: $name produced no PNG" >&2; exit 2; }
}

run_config accel-on  "$ACCEL_QC"
run_config accel-off ""

if [[ "$REBASELINE" == "1" ]]; then
    mkdir -p "$BASE/png-accel-on" "$BASE/png-accel-off"
    cp "$WORK/accel-on.json"  "$BASE/mac-stress-1080p-accel-on.json"
    cp "$WORK/accel-off.json" "$BASE/mac-stress-1080p-accel-off.json"
    cp "$WORK/png-accel-on/$SCENE.png"  "$BASE/png-accel-on/"
    cp "$WORK/png-accel-off/$SCENE.png" "$BASE/png-accel-off/"
    echo "==> REBASELINED. Review + commit the Baselines/ changes."
    exit 0
fi

rc=0
python3 - "$WORK" "$BASE" "$TOLERANCE_PCT" "$STEPS_TOLERANCE_PCT" "$SCENE" <<'EOF' || rc=$?
import json, sys, pathlib
work, base, tol, steps_tol, scene = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
fail = False
for name in ("accel-on", "accel-off"):
    cur = json.load(open(work / f"{name}.json"))["scenes"][0]
    ref = json.load(open(base / f"mac-stress-1080p-{name}.json"))["scenes"][0]
    d_gpu = 100.0 * (cur["gpuMsAvg"] - ref["gpuMsAvg"]) / ref["gpuMsAvg"]
    d_steps = 100.0 * (cur["iterationsAvg"] - ref["iterationsAvg"]) / max(ref["iterationsAvg"], 1e-9)
    png_cur = (work / f"png-{name}" / f"{scene}.png").read_bytes()
    png_ref_path = base / f"png-{name}" / f"{scene}.png"
    png_ok = png_ref_path.exists() and png_cur == png_ref_path.read_bytes()
    status = []
    if d_gpu > tol:              status.append(f"GPU REGRESSION +{d_gpu:.1f}%"); fail = True
    elif d_gpu < -tol:           status.append(f"improved {d_gpu:.1f}% (consider --rebaseline)")
    if abs(d_steps) > steps_tol: status.append(f"STEPS DRIFT {d_steps:+.1f}%"); fail = True
    if not png_ok:               status.append("PNG MISMATCH (visual change)"); fail = True
    verdict = "; ".join(status) if status else "ok"
    print(f"{name}: gpu {ref['gpuMsAvg']:.2f} -> {cur['gpuMsAvg']:.2f} ms ({d_gpu:+.1f}%), "
          f"steps {ref['iterationsAvg']:.1f} -> {cur['iterationsAvg']:.1f} — {verdict}")
sys.exit(1 if fail else 0)
EOF
if [[ $rc -eq 0 ]]; then echo "==> PERF GATE PASSED"; else echo "==> PERF GATE FAILED" >&2; fi
exit $rc
