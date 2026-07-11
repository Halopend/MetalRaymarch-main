#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/halopend/Threshold/MetalRaymarch-main"
OUT="$ROOT/BenchmarkResults/desktop-threadgroup-size-2026-07-09"
APP="/private/tmp/threshold-threadgroup-dd/Build/Products/Debug/Threshold.app/Contents/MacOS/Threshold"
LOG_DIR="$OUT/logs"
mkdir -p "$LOG_DIR"

run_one() {
  local mode="$1"
  local tile="$2"
  local run="$3"
  local label="$4"
  local size="$5"
  local log="$LOG_DIR/${mode}_${label}_run${run}.log"
  local json="/tmp/threshold_${mode}_${label}_run${run}.json"
  local tag="${mode}_${label}_run${run}"

  if [[ "$tile" == "NA" ]]; then
    env THRESHOLD_BENCHMARK=1 \
      THRESHOLD_BENCHMARK_SCENES=Start \
      THRESHOLD_BENCHMARK_FRAMES=90 \
      THRESHOLD_BENCHMARK_WARMUP=20 \
      THRESHOLD_BENCHMARK_SIZE="$size" \
      THRESHOLD_BENCHMARK_SHADOWS=1 \
      THRESHOLD_BENCHMARK_OUT="$json" \
      THRESHOLD_PERF_TAG="$tag" \
      "$APP" > "$log" 2>&1
  else
    env THRESHOLD_BENCHMARK=1 \
      THRESHOLD_BENCHMARK_SCENES=Start \
      THRESHOLD_BENCHMARK_FRAMES=90 \
      THRESHOLD_BENCHMARK_WARMUP=20 \
      THRESHOLD_BENCHMARK_SIZE="$size" \
      THRESHOLD_BENCHMARK_SHADOWS=1 \
      THRESHOLD_BENCHMARK_OUT="$json" \
      THRESHOLD_PERF_TAG="$tag" \
      THRESHOLD_BENCHMARK_COMPUTE_TILE="$tile" \
      "$APP" > "$log" 2>&1
  fi
}

for run in 1 2 3; do
  for spec in "720p:1280x720" "1080p:1920x1080" "1440p:2560x1440"; do
    label="${spec%%:*}"
    size="${spec#*:}"
    run_one "fragment" "NA" "$run" "$label" "$size"
    run_one "compute4" "4" "$run" "$label" "$size"
    run_one "compute8" "8" "$run" "$label" "$size"
    run_one "compute16" "16" "$run" "$label" "$size"
  done
done

python3 - "$OUT" <<'PY'
import csv
import math
import re
import statistics
import sys
from pathlib import Path

out = Path(sys.argv[1])
log_dir = out / "logs"
raw_path = out / "threadgroup-fps-raw.csv"
summary_path = out / "threadgroup-fps-summary.csv"

job_re = re.compile(r"job '([^']+)': scene '([^']+)' (\d+)x(\d+) frames=(\d+) warmup=(\d+)")
metric_re = re.compile(r"'([^']+)' -> gpu avg ([0-9.]+)ms  p95 ([0-9.]+)ms  max ([0-9.]+)ms  steps ([0-9.]+)  cpuEnc ([0-9.]+)ms")
metric_re_alt = re.compile(r"'([^']+)' .* gpu avg ([0-9.]+)ms  p95 ([0-9.]+)ms  max ([0-9.]+)ms  steps ([0-9.]+)  cpuEnc ([0-9.]+)ms")
pipe_re = re.compile(r"compute tile (\d+)x(\d+) threadsPerThreadgroup=(\d+) maxThreadsPerThreadgroup=(\d+) threadExecutionWidth=(\d+) threadgroupMemBytes=(\d+)")

rows = []
for log in sorted(log_dir.glob("*.log")):
    m = re.match(r"(fragment|compute(\d+))_(720p|1080p|1440p)_run(\d+)\.log$", log.name)
    if not m:
        continue
    mode = m.group(1)
    tile = m.group(2) or ""
    resolution_label = m.group(3)
    run = int(m.group(4))
    path = "fragment" if mode == "fragment" else "compute"
    tile_size = "NA" if path == "fragment" else tile
    threads = "NA" if path == "fragment" else str(int(tile) * int(tile))
    max_threads = "NA"
    tew = "NA"
    tgm = "NA"
    current = None
    for line in log.read_text(errors="replace").splitlines():
        pm = pipe_re.search(line)
        if pm:
            max_threads = pm.group(4)
            tew = pm.group(5)
            tgm = pm.group(6)
        jm = job_re.search(line)
        if jm:
            current = {
                "job": jm.group(1),
                "scene": jm.group(2),
                "width": int(jm.group(3)),
                "height": int(jm.group(4)),
                "frames": int(jm.group(5)),
                "warmup": int(jm.group(6)),
            }
            continue
        mm = metric_re.search(line) or metric_re_alt.search(line)
        if mm and current:
            gpu_avg = float(mm.group(2))
            gpu_p95 = float(mm.group(3))
            gpu_max = float(mm.group(4))
            steps = float(mm.group(5))
            cpu = float(mm.group(6))
            occupancy_ratio = ""
            if path == "compute" and max_threads != "NA" and int(max_threads) > 0:
                occupancy_ratio = f"{(int(threads) / int(max_threads)):.4f}"
            rows.append({
                "run": run,
                "path": path,
                "tileSize": tile_size,
                "resolution": resolution_label,
                "width": current["width"],
                "height": current["height"],
                "frames": current["frames"],
                "warmup": current["warmup"],
                "threadsPerThreadgroup": threads,
                "maxThreadsPerThreadgroup": max_threads,
                "threadExecutionWidth": tew,
                "threadgroupMemBytes": tgm,
                "occupancyRatioThreadsOverMax": occupancy_ratio,
                "gpuMsAvg": f"{gpu_avg:.3f}",
                "gpuMsP95": f"{gpu_p95:.3f}",
                "gpuMsMax": f"{gpu_max:.3f}",
                "fpsAvg": f"{(1000.0 / gpu_avg):.3f}" if gpu_avg > 0 else "0.000",
                "fpsMin": f"{(1000.0 / gpu_max):.3f}" if gpu_max > 0 else "0.000",
                "cpuEncodeMsAvg": f"{cpu:.3f}",
                "stepsAvg": f"{steps:.3f}",
                "note": "fragment has no threadgroup size" if path == "fragment" else "compute step counter unavailable in this harness",
                "log": str(log),
            })
            current = None

fieldnames = [
    "run", "path", "tileSize", "resolution", "width", "height", "frames", "warmup",
    "threadsPerThreadgroup", "maxThreadsPerThreadgroup", "threadExecutionWidth", "threadgroupMemBytes",
    "occupancyRatioThreadsOverMax", "gpuMsAvg", "gpuMsP95", "gpuMsMax", "fpsAvg", "fpsMin",
    "cpuEncodeMsAvg", "stepsAvg", "note", "log"
]
with raw_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

groups = {}
for row in rows:
    key = (row["path"], row["tileSize"], row["resolution"], row["width"], row["height"])
    groups.setdefault(key, []).append(row)

summary_rows = []
for (path, tile, res, width, height), group in sorted(groups.items(), key=lambda x: (int(x[0][3]), x[0][0], str(x[0][1]))):
    fps = [float(r["fpsAvg"]) for r in group]
    gpu = [float(r["gpuMsAvg"]) for r in group]
    summary_rows.append({
        "path": path,
        "tileSize": tile,
        "resolution": res,
        "width": width,
        "height": height,
        "runs": len(group),
        "threadsPerThreadgroup": group[0]["threadsPerThreadgroup"],
        "maxThreadsPerThreadgroup": group[0]["maxThreadsPerThreadgroup"],
        "threadExecutionWidth": group[0]["threadExecutionWidth"],
        "threadgroupMemBytes": group[0]["threadgroupMemBytes"],
        "occupancyRatioThreadsOverMax": group[0]["occupancyRatioThreadsOverMax"],
        "fpsMean": f"{statistics.mean(fps):.3f}",
        "fpsStdev": f"{statistics.stdev(fps):.3f}" if len(fps) > 1 else "0.000",
        "fpsBestRun": f"{max(fps):.3f}",
        "fpsWorstRun": f"{min(fps):.3f}",
        "gpuMsMean": f"{statistics.mean(gpu):.3f}",
        "gpuMsStdev": f"{statistics.stdev(gpu):.3f}" if len(gpu) > 1 else "0.000",
        "winnerWithinResolution": "",
        "note": "fragment baseline; not a threadgroup-sizing option" if path == "fragment" else "",
    })

for res in sorted({r["resolution"] for r in summary_rows}):
    compute = [r for r in summary_rows if r["resolution"] == res and r["path"] == "compute"]
    if compute:
        winner = max(compute, key=lambda r: float(r["fpsMean"]))
        winner["winnerWithinResolution"] = "best_compute_tile"

summary_fields = [
    "path", "tileSize", "resolution", "width", "height", "runs",
    "threadsPerThreadgroup", "maxThreadsPerThreadgroup", "threadExecutionWidth",
    "threadgroupMemBytes", "occupancyRatioThreadsOverMax", "fpsMean", "fpsStdev",
    "fpsBestRun", "fpsWorstRun", "gpuMsMean", "gpuMsStdev", "winnerWithinResolution", "note"
]
with summary_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=summary_fields)
    writer.writeheader()
    writer.writerows(summary_rows)

print(raw_path)
print(summary_path)
PY
