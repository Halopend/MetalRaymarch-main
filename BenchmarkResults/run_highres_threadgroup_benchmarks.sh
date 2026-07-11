#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/halopend/Threshold/MetalRaymarch-main"
OUT="$ROOT/BenchmarkResults/desktop-threadgroup-highres-2026-07-09"
APP="/private/tmp/threshold-threadgroup-dd/Build/Products/Debug/Threshold.app/Contents/MacOS/Threshold"
LOG_DIR="$OUT/logs"
FRAMES="${THRESHOLD_BENCHMARK_FRAMES:-180}"
WARMUP="${THRESHOLD_BENCHMARK_WARMUP:-120}"
mkdir -p "$LOG_DIR"

run_one() {
  local mode="$1"
  local tile="$2"
  local run="$3"
  local label="$4"
  local size="$5"
  local log="$LOG_DIR/${mode}_${label}_run${run}.log"
  local tag="${mode}_${label}_run${run}"

  if [[ "$tile" == "NA" ]]; then
    env THRESHOLD_BENCHMARK=1 \
      THRESHOLD_BENCHMARK_SCENES=Start \
      THRESHOLD_BENCHMARK_FRAMES="$FRAMES" \
      THRESHOLD_BENCHMARK_WARMUP="$WARMUP" \
      THRESHOLD_BENCHMARK_SIZE="$size" \
      THRESHOLD_BENCHMARK_SHADOWS=1 \
      THRESHOLD_PERF_TAG="$tag" \
      "$APP" > "$log" 2>&1
  else
    env THRESHOLD_BENCHMARK=1 \
      THRESHOLD_BENCHMARK_SCENES=Start \
      THRESHOLD_BENCHMARK_FRAMES="$FRAMES" \
      THRESHOLD_BENCHMARK_WARMUP="$WARMUP" \
      THRESHOLD_BENCHMARK_SIZE="$size" \
      THRESHOLD_BENCHMARK_SHADOWS=1 \
      THRESHOLD_PERF_TAG="$tag" \
      THRESHOLD_BENCHMARK_COMPUTE_TILE="$tile" \
      "$APP" > "$log" 2>&1
  fi
}

for run in 1 2 3; do
  for spec in \
    "1440p:2560x1440" \
    "1620p:2880x1620" \
    "1800p:3200x1800" \
    "2160p:3840x2160" \
    "2880p:5120x2880"; do
    label="${spec%%:*}"
    size="${spec#*:}"
    run_one "fragment" "NA" "$run" "$label" "$size"
    run_one "compute4" "4" "$run" "$label" "$size"
    run_one "compute8" "8" "$run" "$label" "$size"
    run_one "compute16" "16" "$run" "$label" "$size"
  done
done

python3 - "$OUT" "$FRAMES" "$WARMUP" <<'PY'
import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

out = Path(sys.argv[1])
expected_frames = int(sys.argv[2])
expected_warmup = int(sys.argv[3])
log_dir = out / "logs"
raw_path = out / "threadgroup-fps-raw.csv"
summary_path = out / "threadgroup-fps-summary.csv"

job_re = re.compile(r"job '([^']+)': scene '([^']+)' (\d+)x(\d+) frames=(\d+) warmup=(\d+)")
metric_re = re.compile(r"'([^']+)' .* gpu avg ([0-9.]+)ms  p95 ([0-9.]+)ms  max ([0-9.]+)ms  steps ([0-9.]+)  cpuEnc ([0-9.]+)ms")
pipe_re = re.compile(r"compute tile (\d+)x\1 threadsPerThreadgroup=(\d+) maxThreadsPerThreadgroup=(\d+) threadExecutionWidth=(\d+) threadgroupMemBytes=(\d+)")
file_re = re.compile(r"(fragment|compute(\d+))_([^_]+)_run(\d+)\.log$")

rows = []
for log in sorted(log_dir.glob("*.log")):
    match = file_re.match(log.name)
    if not match:
        continue
    mode = match.group(1)
    tile = match.group(2) or ""
    resolution = match.group(3)
    run = int(match.group(4))
    path = "fragment" if mode == "fragment" else "compute"
    tile_size = "NA" if path == "fragment" else tile
    threads = "NA" if path == "fragment" else str(int(tile) * int(tile))
    max_threads = "NA"
    execution_width = "NA"
    threadgroup_memory = "NA"
    current = None

    for line in log.read_text(errors="replace").splitlines():
        pipeline = pipe_re.search(line)
        if pipeline:
            max_threads = pipeline.group(3)
            execution_width = pipeline.group(4)
            threadgroup_memory = pipeline.group(5)
        job = job_re.search(line)
        if job:
            current = {
                "job": job.group(1),
                "scene": job.group(2),
                "width": int(job.group(3)),
                "height": int(job.group(4)),
                "frames": int(job.group(5)),
                "warmup": int(job.group(6)),
            }
            continue
        metric = metric_re.search(line)
        if not metric or not current:
            continue
        gpu_avg = float(metric.group(2))
        gpu_p95 = float(metric.group(3))
        gpu_max = float(metric.group(4))
        steps = float(metric.group(5))
        cpu = float(metric.group(6))
        occupancy_ratio = ""
        if path == "compute" and max_threads != "NA" and int(max_threads) > 0:
            occupancy_ratio = f"{int(threads) / int(max_threads):.4f}"
        rows.append({
            "run": run,
            "path": path,
            "tileSize": tile_size,
            "resolution": resolution,
            "width": current["width"],
            "height": current["height"],
            "frames": current["frames"],
            "warmup": current["warmup"],
            "threadsPerThreadgroup": threads,
            "maxThreadsPerThreadgroup": max_threads,
            "threadExecutionWidth": execution_width,
            "threadgroupMemBytes": threadgroup_memory,
            "occupancyRatioThreadsOverMax": occupancy_ratio,
            "gpuMsAvg": f"{gpu_avg:.3f}",
            "gpuMsP95": f"{gpu_p95:.3f}",
            "gpuMsMax": f"{gpu_max:.3f}",
            "fpsAvg": f"{1000.0 / gpu_avg:.3f}" if gpu_avg > 0 else "0.000",
            "fpsMin": f"{1000.0 / gpu_max:.3f}" if gpu_max > 0 else "0.000",
            "cpuEncodeMsAvg": f"{cpu:.3f}",
            "stepsAvg": f"{steps:.3f}",
            "note": "fragment has no threadgroup size" if path == "fragment" else "compute step counter unavailable in this harness",
            "log": str(log),
        })
        current = None

expected_rows = 5 * 4 * 3
if len(rows) != expected_rows:
    raise SystemExit(f"expected {expected_rows} complete benchmark rows, found {len(rows)}")

groups = defaultdict(list)
for row in rows:
    groups[(row["path"], row["tileSize"], row["resolution"], row["width"], row["height"])].append(row)
if any(len(group) != 3 for group in groups.values()):
    raise SystemExit("every configuration must have exactly three runs")
if any(int(row["frames"]) != expected_frames or int(row["warmup"]) != expected_warmup for row in rows):
    raise SystemExit("a benchmark row has unexpected frame or warmup counts")

raw_fields = [
    "run", "path", "tileSize", "resolution", "width", "height", "frames", "warmup",
    "threadsPerThreadgroup", "maxThreadsPerThreadgroup", "threadExecutionWidth", "threadgroupMemBytes",
    "occupancyRatioThreadsOverMax", "gpuMsAvg", "gpuMsP95", "gpuMsMax", "fpsAvg", "fpsMin",
    "cpuEncodeMsAvg", "stepsAvg", "note", "log"
]
with raw_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=raw_fields)
    writer.writeheader()
    writer.writerows(rows)

summary_rows = []
for (path, tile, resolution, width, height), group in sorted(groups.items(), key=lambda item: (int(item[0][3]), item[0][0], str(item[0][1]))):
    fps = [float(row["fpsAvg"]) for row in group]
    gpu = [float(row["gpuMsAvg"]) for row in group]
    summary_rows.append({
        "path": path,
        "tileSize": tile,
        "resolution": resolution,
        "width": width,
        "height": height,
        "frames": group[0]["frames"],
        "warmup": group[0]["warmup"],
        "runs": len(group),
        "threadsPerThreadgroup": group[0]["threadsPerThreadgroup"],
        "maxThreadsPerThreadgroup": group[0]["maxThreadsPerThreadgroup"],
        "threadExecutionWidth": group[0]["threadExecutionWidth"],
        "threadgroupMemBytes": group[0]["threadgroupMemBytes"],
        "occupancyRatioThreadsOverMax": group[0]["occupancyRatioThreadsOverMax"],
        "fpsMean": f"{statistics.mean(fps):.3f}",
        "fpsStdev": f"{statistics.stdev(fps):.3f}",
        "fpsBestRun": f"{max(fps):.3f}",
        "fpsWorstRun": f"{min(fps):.3f}",
        "gpuMsMean": f"{statistics.mean(gpu):.3f}",
        "gpuMsStdev": f"{statistics.stdev(gpu):.3f}",
        "winnerWithinResolution": "",
        "note": "fragment baseline; not a threadgroup-sizing option" if path == "fragment" else "",
    })

for resolution in sorted({row["resolution"] for row in summary_rows}):
    compute = [row for row in summary_rows if row["resolution"] == resolution and row["path"] == "compute"]
    max(compute, key=lambda row: float(row["fpsMean"]))["winnerWithinResolution"] = "best_compute_tile"

summary_fields = [
    "path", "tileSize", "resolution", "width", "height", "frames", "warmup", "runs",
    "threadsPerThreadgroup", "maxThreadsPerThreadgroup", "threadExecutionWidth", "threadgroupMemBytes",
    "occupancyRatioThreadsOverMax", "fpsMean", "fpsStdev", "fpsBestRun", "fpsWorstRun",
    "gpuMsMean", "gpuMsStdev", "winnerWithinResolution", "note"
]
with summary_path.open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=summary_fields)
    writer.writeheader()
    writer.writerows(summary_rows)

print(raw_path)
print(summary_path)
PY
