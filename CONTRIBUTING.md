# Building & testing Threshold

This project builds for **macOS, iPadOS, and visionOS** (not iPhone). Most local
iteration happens against the **macOS** target — it compiles all of the Swift and
Metal in seconds and is the fastest way to catch breakage.

## TL;DR

```sh
Scripts/build.sh mac      # build ThresholdMac (full Swift + Metal compile check)
Scripts/build.sh test     # run the unit suite (ThresholdTests) on macOS
Scripts/build.sh vision   # build the visionOS scheme (generic device)
Scripts/build.sh embeds   # regenerate EmbeddedMetalSources.swift after a shader/header edit
Scripts/build.sh all      # embeds + mac + vision + test
```

## The toolchain trap (read this first)

The command-line `xcodebuild` default toolchain is frequently the **wrong Xcode**
for this project — it builds against an older SDK and fails or silently misbehaves.
This project must build with the Xcode **beta** whose SDK matches the code
(macOS 26 / visionOS 26). `Scripts/build.sh` auto-detects the beta: it sets
`DEVELOPER_DIR` to the first that exists, preferring
`/Applications/Xcode-beta.app` and falling back to `/Applications/Xcode-beta 2.app`
(the old hardcoded `Xcode-beta 2.app` default was stale and broke fresh clones).
Override it when your beta lives elsewhere:

```sh
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" Scripts/build.sh mac
```

## Schemes & targets

| Scheme        | Target        | Platform   | Notes                                  |
|---------------|---------------|------------|----------------------------------------|
| `Threshold`   | `Threshold`   | visionOS   | The primary app. Owns the test action. |
| `ThresholdMac`| `ThresholdMac`| macOS      | Fastest full compile; runs the tests.  |
| `ThresholdiOS`| `ThresholdiOS`| iPadOS     |                                        |
| —             | `ThresholdTests` | macOS   | Swift Testing unit suite.              |

Builds pass `CODE_SIGNING_ALLOWED=NO` to avoid provisioning friction locally.

## Running the tests

```sh
Scripts/build.sh test
# == xcodebuild test -scheme ThresholdMac -configuration Debug \
#       -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The suite uses **Swift Testing** (`import Testing`, `@Suite`/`@Test`/`#expect`),
not XCTest. Test files live in `ThresholdTests/` and are picked up automatically
(the target uses an Xcode file-system-synchronized group — no manual pbxproj
membership needed; just drop a `.swift` file in the folder).

### Note on the test target (history)

The `ThresholdTests` target was previously **not runnable from the command line**:
its `buildPhases` were empty (so `xcodebuild` compiled no sources and produced an
executable-less `.xctest` bundle), and its `MACOSX_DEPLOYMENT_TARGET` (15.0) was
below the app module's minimum (26.0). Both are now fixed in `project.pbxproj`, so
`Scripts/build.sh test` works in CI and locally. If you add a *new* test target,
make sure it has explicit `Sources`/`Frameworks` build phases and a matching
deployment target.

## After editing shaders

Any change to `Threshold/Rendering/Shaders.metal`, `ShaderTypes.h`, or a built-in
formula header **must** be followed by:

```sh
Scripts/build.sh embeds   # regenerates Threshold/Rendering/Generated/EmbeddedMetalSources.swift
```

That generated file embeds the Metal sources so the runtime shader compiler can
build self-contained `.threshfx` formulas; it must mirror the static build.

## Known quirks

- The iOS simulator target is finicky; prefer the macOS target for quick checks
  and a real device / visionOS for behavioral and performance validation.
- visionOS-only code paths only compile under the `Threshold` scheme — build that
  scheme (`Scripts/build.sh vision`) before assuming a visionOS-only change is sound.
- Performance-sensitive changes (the per-frame render/audio paths) must be
  validated on Vision Pro — the device is GPU-bound and the simulator/Mac will not
  surface frame-time regressions.

## Performance claims

Do **not** cite a performance number (an `N×` speedup, a `<1 ms`, an fps, a
"saves N evaluations") unless it came from a real on-device measurement.

- The **only** citable source of perf numbers is [`PERF_LOG.md`](PERF_LOG.md) /
  `PERF_LOG.jsonl`, captured by the in-app Vision Pro benchmark sweep.
- The magnitudes in `Threshold/Rendering/PERF_TECHNIQUES.md` are **unverified
  estimates inferred from reading the code** — useful for locating *where* cost
  lives, never as proof of *how much* a change saves. That document's `STATUS:`
  markers and `file:line` references are code-grounded and fine to rely on; its
  numbers are not.
- When a PR or commit message needs to justify a perf change, measure it on
  device and quote the `PERF_LOG` figure. "Should be faster" with no number is
  better than an invented one.
