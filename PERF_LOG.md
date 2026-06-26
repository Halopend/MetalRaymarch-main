# Threshold — Vision Pro Performance Log

Per-build performance history, measured **on the actual Vision Pro** (GPU/CPU
numbers from the Simulator are meaningless — it runs on the Mac's GPU).

## How it works

1. Build & deploy to the Vision Pro.
2. Open the immersive view, then in **Settings → Performance Sweep** tap
   **Run Benchmark Sweep**. It loads a curated set of scenes (one per fractal
   type), measures each for a few seconds, and appends one JSON record to
   `Documents/PerfLog/perf-log.jsonl` plus a readable block to `perf-log.md`
   on the device.
3. Pull those two files off the headset (Files app → On My Apple Vision Pro →
   Threshold → PerfLog, or via iCloud Drive).
4. Append the new line(s) from the device `perf-log.jsonl` to this repo's
   [`PERF_LOG.jsonl`](PERF_LOG.jsonl), and paste the device `perf-log.md` block
   below the `---` here. Commit. Now perf is tracked across builds in git.

## Record shape

Each line in `PERF_LOG.jsonl` is one run (`schemaVersion: 1`), keyed by
`gitSHA` + `buildNumber` + `capturedAt`, with a `scenes[]` array. Headline
metric is **`gpuMsAvg` / `gpuMsP95`** per scene — continuous render cost,
independent of the vsync-quantized FPS. Lower is faster; under ~11.1 ms is the
90 fps budget on Vision Pro.

To diff two builds, compare the same scene's `gpuMsP95` across their records.

> The git SHA is stamped into the build by the "Stamp Git SHA" Xcode build
> phase. A build made without that phase logs `gitSHA: "unknown"`.

---

<!-- Paste device perf-log.md blocks below, newest first. -->
