# Threshold

An artistic real-time fractal renderer (SDF ray-marching in Metal) for **macOS, iPadOS, and visionOS**, with a music-reactive layer, an animation/scene system, and a Quick Look extension that live-renders `.threshscene` files.

This file is the fast orientation for a fresh clone. Deeper docs:
[`CONTRIBUTING.md`](CONTRIBUTING.md) (full build/test guide) ·
[`ROADMAP.md`](ROADMAP.md) (ordered active work) ·
[`TECH_DEBT.md`](TECH_DEBT.md) + [`Context/TECH_DEBT_AUDIT_2026-07-07.md`](Context/TECH_DEBT_AUDIT_2026-07-07.md) (debt register) ·
[`PERF_PUSH.md`](PERF_PUSH.md) (perf backlog) · [`Context/`](Context/) (architecture).

## Requirements

- **Xcode 26 or newer with the macOS/iOS/visionOS 26 SDKs** (Swift 6). All three targets set `*_DEPLOYMENT_TARGET = 26.0`.
- The build scripts prefer `/Applications/Xcode-beta.app`, then use the active full Xcode selected by `xcode-select`. Override explicitly when needed:
  ```sh
  DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" Scripts/build.sh mac
  ```

## Build & run

```sh
Scripts/build.sh mac       # ThresholdMac (fastest iteration; fragment render path)
Scripts/build.sh vision    # Threshold (visionOS; compute render path)
Scripts/build.sh ios       # ThresholdiOS
Scripts/build.sh test      # clean test — the ONLY trustworthy test run (see below)
Scripts/build.sh embeds    # generate an inspection copy of the embedded Metal sources
```
Local builds run with `CODE_SIGNING_ALLOWED=NO` (no provisioning needed).

## Gotchas that will bite you (keep these in muscle memory)

1. **Shader embeds are automatic.** Each app and Quick Look target generates `EmbeddedMetalSources.swift` into its own Derived Sources directory before Swift compilation. Editing `Shaders.metal`, `ShaderTypes.h`, or a built-in formula header therefore updates both the static Metal build and runtime `.threshfx` compiler input in the same build. `Scripts/build.sh embeds` remains available only to inspect the generated Swift under `.build/Generated`.

2. **Edited a shader? Also clear the pipeline cache.** Dev builds reuse a stale PSO archive across shader changes:
   ```sh
   rm -rf "$HOME/Library/Application Support/ThresholdPipelineArchive"
   ```

3. **Only `clean test` is trustworthy.** Incremental builds can link a stale `Threshold.swiftmodule` and report a false "TEST SUCCEEDED"; parallel MTLDevice test hosts also crash into phantom failures. `Scripts/build.sh test` forces `clean` + `-parallel-testing-enabled NO`. `testfast` is the incremental (untrustworthy-pass) variant.

4. **Unsigned build + signed into iCloud = a CloudKit trap.** With `CODE_SIGNING_ALLOWED=NO` the app has no iCloud entitlement, but if you're signed into iCloud the analytics uploader used to throw an *uncaught* ObjC exception and **freeze the app in a crash-reporter modal** (looks like "the app hangs"). Guarded since 2026-07-07 by `UsageAnalytics.hasCloudKitEntitlement` (`SecTaskCopyValueForEntitlement`). If a freeze-on-launch ever returns, look there first — `sample <pid>` the process to confirm.

5. **CI protects every push and pull request.** It runs repository hygiene, clean serial tests, iPadOS/visionOS builds, and the Quick Look render gate. Performance timing remains local/on-device because hosted-runner GPU numbers are not stable evidence.

## Local commit guard (opt-in)

A pre-commit hook rejects accidental Finder/Xcode "Duplicate" files (`Foo 2.swift`, `Bar copy.metal` — this repo has been bitten by exactly that). Enable it once per clone:
```sh
git config core.hooksPath .githooks
```
Bypass a single commit with `git commit --no-verify`.
