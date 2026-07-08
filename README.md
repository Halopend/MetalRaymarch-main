# Threshold

An artistic real-time fractal renderer (SDF ray-marching in Metal) for **macOS, iPadOS, and visionOS**, with a music-reactive layer, an animation/scene system, and a Quick Look extension that live-renders `.threshscene` files.

This file is the fast orientation for a fresh clone. Deeper docs:
[`CONTRIBUTING.md`](CONTRIBUTING.md) (full build/test guide) ·
[`TECH_DEBT.md`](TECH_DEBT.md) + [`Context/TECH_DEBT_AUDIT_2026-07-07.md`](Context/TECH_DEBT_AUDIT_2026-07-07.md) (debt register) ·
[`PERF_PUSH.md`](PERF_PUSH.md) (perf backlog) · [`Context/`](Context/) (architecture).

## Requirements

- **Xcode beta with the 26.0 SDKs** (Swift 6). All three targets set `*_DEPLOYMENT_TARGET = 26.0`, so a released Xcode will not build this.
- The build scripts auto-detect the beta at `/Applications/Xcode-beta.app` (falling back to `Xcode-beta 2.app`). Override explicitly if yours lives elsewhere:
  ```sh
  DEVELOPER_DIR="/path/to/Xcode-beta.app/Contents/Developer" Scripts/build.sh mac
  ```

## Build & run

```sh
Scripts/build.sh mac       # ThresholdMac (fastest iteration; fragment render path)
Scripts/build.sh vision    # Threshold (visionOS; compute render path)
Scripts/build.sh ios       # ThresholdiOS
Scripts/build.sh test      # clean test — the ONLY trustworthy test run (see below)
Scripts/build.sh embeds    # regenerate the embedded Metal sources (see gotchas)
```
Local builds run with `CODE_SIGNING_ALLOWED=NO` (no provisioning needed).

## Gotchas that will bite you (keep these in muscle memory)

1. **Edited a shader? Regenerate the embeds.** After changing `Shaders.metal`, `ShaderTypes.h`, or any `Threshold/Formulas/**/*.h`, run `Scripts/generate_metal_embeds.sh` (or `Scripts/build.sh embeds`). `Threshold/Rendering/Generated/EmbeddedMetalSources.swift` is a **hand-regenerated** verbatim copy used by the runtime `.threshfx` compiler — it is *not* rebuilt automatically. A forgotten regen ships stale runtime shaders; `ThresholdTests/EmbedFreshnessTests` catches it, but only when tests run.

2. **Edited a shader? Also clear the pipeline cache.** Dev builds reuse a stale PSO archive across shader changes:
   ```sh
   rm -rf "$HOME/Library/Application Support/ThresholdPipelineArchive"
   ```

3. **Only `clean test` is trustworthy.** Incremental builds can link a stale `Threshold.swiftmodule` and report a false "TEST SUCCEEDED"; parallel MTLDevice test hosts also crash into phantom failures. `Scripts/build.sh test` forces `clean` + `-parallel-testing-enabled NO`. `testfast` is the incremental (untrustworthy-pass) variant.

4. **Unsigned build + signed into iCloud = a CloudKit trap.** With `CODE_SIGNING_ALLOWED=NO` the app has no iCloud entitlement, but if you're signed into iCloud the analytics uploader used to throw an *uncaught* ObjC exception and **freeze the app in a crash-reporter modal** (looks like "the app hangs"). Guarded since 2026-07-07 by `UsageAnalytics.hasCloudKitEntitlement` (`SecTaskCopyValueForEntitlement`). If a freeze-on-launch ever returns, look there first — `sample <pid>` the process to confirm.

5. **There is no CI.** Nothing runs the tests/perf/Quick Look gates for you. Before pushing, run `Scripts/build.sh test` (and `Scripts/perf-gate.sh` / `Scripts/ql_render_check.sh` if you touched rendering).

## Local commit guard (opt-in)

A pre-commit hook rejects accidental Finder/Xcode "Duplicate" files (`Foo 2.swift`, `Bar copy.metal` — this repo has been bitten by exactly that). Enable it once per clone:
```sh
git config core.hooksPath .githooks
```
Bypass a single commit with `git commit --no-verify`.
