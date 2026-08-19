# Building & testing Threshold

This project builds for **macOS, iPadOS, and visionOS** (not iPhone). Most local
iteration happens against the **macOS** target — it compiles all of the Swift and
Metal in seconds and is the fastest way to catch breakage.

## Contribution licensing and provenance

Unless the maintainers agree in writing to different terms for clearly
identified material before it is submitted, an intentional contribution to
Threshold's covered project code is submitted under **GPL-3.0-or-later**, the
same license used for the project. Contributors keep the copyright in their
work; this policy does not require copyright assignment.

By submitting a contribution, you represent that you have the authority to
license it on those terms. Do not submit copied or adapted code, formulas,
shaders, models, music, images, sample scenes, or other material unless its
provenance and license are documented and compatible with the destination.
Attribution or a link to a source is not a license. If a contribution changes
the starter source copied into user exports, generated scaffolding, bundled
samples, documentation, or non-code assets, state the intended license for that
material explicitly in the pull request.

See [`LICENSE`](LICENSE), [`NOTICE.md`](NOTICE.md), and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before contributing.

## TL;DR

```sh
Scripts/build.sh mac      # build ThresholdMac (full Swift + Metal compile check)
Scripts/build.sh test     # run the unit suite (ThresholdTests) on macOS
Scripts/build.sh vision   # build the visionOS scheme (generic device)
Scripts/build.sh embeds   # regenerate EmbeddedMetalSources.swift after a shader/header edit
Scripts/build.sh all      # embeds + mac + vision + test
```

## The toolchain trap (read this first)

The command-line `xcodebuild` default toolchain can point at an older SDK and
fail or silently misbehave. Threshold requires Xcode 26+ with the macOS/iOS/
visionOS 26 SDKs. `Scripts/build.sh` prefers `/Applications/Xcode-beta.app`,
then uses the active full Xcode selected by `xcode-select`, and rejects an SDK
older than 26. Override it when Xcode lives elsewhere:

```sh
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" Scripts/build.sh mac
```

## Schemes & targets

| Scheme        | Target        | Platform   | Notes                                  |
|---------------|---------------|------------|----------------------------------------|
| `Threshold`   | `Threshold`   | visionOS   | The primary app. Owns the test action. |
| `ThresholdMac`| `ThresholdMac`| macOS      | Fastest full compile; runs the tests.  |
| `ThresholdiOS`| `ThresholdiOS`| iPadOS     |                                        |
| —             | `ThresholdTests` | macOS   | Swift Testing unit suite.              |

Builds pass `CODE_SIGNING_ALLOWED=NO` to avoid provisioning friction locally.

## Continuous integration

Every push and pull request runs the same repository-owned commands used
locally:

- clean, serial `ThresholdTests` on macOS;
- generic-device iPadOS and visionOS builds;
- the Quick Look all-scenes render gate;
- shell/resource hygiene checks.

Failed test jobs upload a seven-day `.xcresult` artifact. CI deliberately does
not judge GPU performance: use `Scripts/perf-gate.sh` locally and Vision Pro
measurements for performance-sensitive work. See [`ROADMAP.md`](ROADMAP.md) for
the active progression and completion rules.

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

Each app and Quick Look target automatically regenerates its embedded Metal
sources when `Threshold/Rendering/Shaders.metal`, `ShaderTypes.h`, or a built-in
formula header changes. To generate an inspection copy manually, run:

```sh
Scripts/build.sh embeds   # generates an inspection copy under .build/Generated
```

The target-local generated file lets the runtime shader compiler build
self-contained `.threshfx` formulas while staying in sync with the static build.

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
