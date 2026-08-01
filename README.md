# Threshold

An artistic real-time fractal renderer (SDF ray-marching in Metal) for **macOS, iPadOS, and visionOS**, with a music-reactive layer, an animation/scene system, and a Quick Look extension that live-renders `.threshscene` files.

## Why Threshold is open

Threshold is a place to explore real-time fractal art, and it will be better with
more eyes, experiments, and ideas. We would love to build it with you. You do
not need to know every part of the renderer to help: trying the app, reporting a
rough edge, suggesting an interaction, sharing a scene, or improving a sentence
in the documentation all make a difference.

The original application code is released under the GNU General Public License,
version 3 or later. The practical terms are summarized below; the complete GPL
text is the authoritative agreement.

## GPL licensing agreement

Unless a source file or imported asset includes a more specific notice, the
Threshold application code is licensed as **GPL-3.0-or-later**. You may use,
study, copy, modify, and share that covered code, provided you follow the GPL
terms when you redistribute it or distribute a work based on it. In particular:

- Keep the copyright and license notices with the covered code.
- Make the corresponding source available when the GPL requires it.
- License covered modifications and larger combined works under GPL-compatible
  terms, as required by the GPL.
- Include the GPL notice and warranty disclaimer with distributions.

If you submit application-code changes through a pull request, please submit
only work you have the right to share and understand that accepted changes will
be distributed under the project's GPL-3.0-or-later terms. This is a friendly
summary, not a replacement for the license: read the
[full GNU GPL v3 text](https://www.gnu.org/licenses/gpl-3.0.html) before
redistributing the project.

The GPL notice applies to Threshold's original application code. Imported
formulas, shaders, artwork, and other third-party material keep their own
attribution and license notes; those notices remain part of the terms for that
material and must be checked before redistribution.

## Contributing

The easiest way to start is to use Threshold, find something that could be
clearer or more enjoyable, and tell us about it. Improvement feedback, bug
reports, design ideas, testing help, new scenes, and pull requests are all
welcome. A small, focused change is just as valuable as a large feature.

If you would like to contribute code to `main`:

1. Create your own branch and make the change there.
2. Open a pull request targeting `main`; please do not push directly to `main`.
3. Explain what changed, why it helps, and how someone else can try it.
4. Add clear test notes, including the platform, build, scene or preset, steps,
   and result. Mention anything you could not test locally.
5. For interface changes, include before-and-after images labeled with the
   platform, window size or device, and relevant scene/settings.

You do not need a perfect proposal before reaching out. Questions, early ideas,
and anything you would like to share are welcome at
[jean.fradet@me.com](mailto:jean.fradet@me.com). The goal is to make Threshold the
best, most expressive, and most enjoyable thing we can build together.

## Acknowledgements

Threshold has been shaped by many generous communities. Thank you to the
fractal-art community for the images, experiments, and continuing curiosity;
to the signed-distance-field, ray-marching, shader, and real-time graphics
communities for the techniques and conversations that make this work possible;
to the Metal and Apple-platform developer communities for sharing practical
knowledge; and to open-source contributors everywhere who make it normal to
learn in public and build on one another's work.

The ideas in this codebase are informed by published techniques, community
experiments, discussions, examples, and inspirations shared by others. We are
grateful for every contribution, including the ones that helped shape a
direction even when they do not appear as a line of code. Specific formula,
shader, artwork, and third-party attributions remain in their source files and
asset notices. If we have missed a credit or if your work has helped inspire
Threshold, please let us know at
[jean.fradet@me.com](mailto:jean.fradet@me.com) so we can correct or expand this
acknowledgement.

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

## Experimental focus and current boundaries

Threshold is very experimental and intentionally still in motion. The project
is exploring how fractal rendering can keep following the medium's visual
traditions while moving toward a real-time workflow where the distance field,
lighting, and scene state can be computed every frame. It is a research surface
as much as it is an application, so behavior, file formats, performance, and UI
will continue to change.

The rendering methods explored so far include frame-to-frame caching and
upscaling through Apple's native upscaling tools. On visionOS, the current
upscaling path does not provide temporal support. It should therefore not be
read as a finished temporal-reconstruction solution; it is one of the practical
experiments helping us learn where the real-time tradeoffs are.

Ideas under consideration include domain transfers, manual input-function
scaling, and other ways to spend the per-frame compute budget more intelligently.
These are areas for exploration, not promises about the current release. If you
have a rendering idea, an example scene, or a measurement that could help, we
would be glad to hear about it.

## Supported files and portable libraries

Threshold is built around small, exchangeable library files. The formats below
are the current supported surface:

| Format | What it contains | How it is used |
| --- | --- | --- |
| `.threshscene` | A fractal scene or preset, including optional embedded formula data | Load, save, share, and preview a scene |
| `.threshmp` | A music-reactive preset and its audio mappings | Share a reusable music-driven setup |
| `.threshanim` | An animation scene and keyframe sequence | Share an animation without attached music |
| `.threshanimv` | An animation scene with attached music | Share a music-video-style animation |
| `.threshlive` | A readable legend plus LZFSE-compressed animation scene | Share a compact, lossless playable animation |
| `.threshfx` | A standalone custom Metal formula or effect payload | Add a reusable formula to the library |

Embedded distance-estimator (DE) functions are accepted inside supported scene
and animation files. When one is opened, Threshold can validate the embedded
payload, register it as a custom formula, and compile it for live rendering. The
payload must follow Threshold's embedded-formula contract — an arbitrary Metal
file is not automatically safe or compatible — and this runtime compilation
path is still experimental.

Standalone `.threshfx` files placed in the selected library's `Formulas/` folder
are discovered automatically and can be exchanged through Files or the normal
share flow. Scenes, music presets, animations, and formulas live under the
selected storage root in `Scenes/`, `Music Presets/`, `Animations/`, and
`Formulas/`, respectively. This keeps a formula or scene portable without
requiring it to be added to the Xcode project.

### iCloud status

Threshold supports two storage modes: **On This Device** and **iCloud Drive**.
The selected root is the source of truth, and the app watches it for changes.
An always-local `Backups/` folder provides a safety net and is not synced to
iCloud. iCloud availability still depends on the user's account, entitlements,
network, and the build being used. Local command-line builds are intentionally
unsigned (`CODE_SIGNING_ALLOWED=NO`) and do not have the iCloud entitlement, so
iCloud behavior should be validated with a signed device or TestFlight build.
When iCloud is unavailable, local storage remains the reliable fallback.

### Categories are intentionally limited

The formula and scene categories are deliberately small at this stage. They are
useful starting points rather than a complete taxonomy, and custom formulas may
still appear under a general custom category. Better grouping, discovery, and
community-oriented categories are welcome areas for feedback and contribution.

## Five macOS scenes to showcase

For a quick tour of the desktop render path, launch `ThresholdMac` and load
these five bundled scenes:

- [`Crystal Palace`](Threshold/Examples/Scenes/Crystal%20Palace.threshscene) — a
  richly colored Kleinian composition for a first visual impression.
- [`Menger Sphere`](Threshold/Examples/Scenes/Menger%20Sphere.threshscene) —
  compares the classic Menger cube with its spherical transformation controls.
- [`Accidental Sphere Projection`](Threshold/Examples/Scenes/Accidental%20Sphere%20Projection.threshscene)
  — a custom Mandelbox reconstruction that shows Threshold’s embedded-formula
  workflow.
- [`Rock the cradle`](Threshold/Examples/Scenes/Rock_the_cradle.threshscene) —
  a Newton-Raphson heightfield demonstrating a very different, terrain-like
  distance field.
- [`Polychora 24-Cell`](<Threshold/Examples/Custom%20Scene%20Example/Polychora%2024-Cell.threshscene>)
  — a 4D polychoron example rendered through stereographic projection.

## Gotchas that will bite you (keep these in muscle memory)

1. **Shader embeds are automatic.** Each app and Quick Look target generates `EmbeddedMetalSources.swift` into its own Derived Sources directory before Swift compilation. Editing `Shaders.metal`, `ShaderTypes.h`, or a built-in formula header therefore updates both the static Metal build and runtime `.threshfx` compiler input in the same build. `Scripts/build.sh embeds` remains available only to inspect the generated Swift under `.build/Generated`.

2. **Edited a shader? Also clear the pipeline cache.** Dev builds reuse a stale PSO archive across shader changes:
   ```sh
   rm -rf "$HOME/Library/Application Support/ThresholdPipelineArchive"
   ```

3. **Only `clean test` is trustworthy.** Incremental builds can link a stale `Threshold.swiftmodule` and report a false "TEST SUCCEEDED"; parallel MTLDevice test hosts also crash into phantom failures. `Scripts/build.sh test` forces `clean` + `-parallel-testing-enabled NO`. `testfast` is the incremental (untrustworthy-pass) variant.

4. **Unsigned build + signed into iCloud = a CloudKit trap.** With `CODE_SIGNING_ALLOWED=NO` the app has no iCloud entitlement, but if you're signed into iCloud the analytics uploader used to throw an *uncaught* ObjC exception and **freeze the app in a crash-reporter modal** (looks like "the app hangs"). Guarded since 2026-07-07 by `UsageAnalytics.hasCloudKitEntitlement` (`SecTaskCopyValueForEntitlement`). If a freeze-on-launch ever returns, look there first — `sample <pid>` the process to confirm.

5. **CI protects every push and pull request.** It runs repository hygiene, clean serial tests, iPadOS/visionOS builds, and the Quick Look render gate. Performance timing remains local/on-device because hosted-runner GPU numbers are not stable evidence.

## Metrics and diagnostics

MetricKit is registered once during app-model startup for the macOS, iPadOS, and
visionOS app targets. Threshold receives both Apple's daily aggregate metrics and
diagnostic reports, including crash, hang, CPU-exception, and disk-write
diagnostics when the operating system provides them.

Only a local, aggregate summary is retained: payload counts, diagnostic counts,
the covered time range, and the app version. Raw MetricKit payloads and call
stacks are not uploaded to CloudKit. This system diagnostic path is separate from
the existing optional usage-sharing analytics. MetricKit delivery is scheduled
by the operating system, so a local run cannot force an immediate report; use a
TestFlight/device build and inspect the app's MetricKit log category when
validating delivery.

## What to test before opening a pull request

Always run the clean serial suite and the fastest relevant platform build:

```sh
Scripts/build.sh test
Scripts/build.sh mac
```

Add the following checks when the change touches the corresponding area:

- **Shared Swift, persistence, or navigation:** run the relevant unit tests and
  confirm a fresh launch, restore, edit, save, and relaunch. Note the exact test
  command and manual path in the pull request.
- **Metal, shaders, formulas, or rendering:** run `Scripts/build.sh embeds`,
  `Scripts/build.sh mac`, `Scripts/build.sh vision`, and
  `Scripts/ql_render_check.sh` when bundled scenes or Quick Look can be affected.
  Check at least one built-in formula, one custom formula, a scene load, and a
  screenshot or render-path change.
- **iPadOS or shared platform code:** run `Scripts/build.sh ios` and test the
  changed interaction on an iPad or simulator as appropriate.
- **Audio, gestures, animation, or external files:** exercise the happy path,
  cancellation/backgrounding, and relaunch/restore behavior on the target
  device. Include the exact gesture or file sequence tested.
- **Performance-sensitive work:** run `Scripts/perf-gate.sh` only with real
  on-device evidence, and record the device, scene, settings, and before/after
  measurements. Do not infer a performance claim from a simulator.
- **MetricKit changes:** verify that the app starts without delay, that the
  reporter is registered once, that existing report summaries remain local, and
  that no raw payload or call stack is sent through CloudKit. Because delivery is
  OS-scheduled, record whether this was validated with a device/TestFlight build
  or with the unit-level summary tests.

For interface adjustments, attach before-and-after images to the pull request.
Label each image with the platform, window size or device, and the relevant
scene/settings so reviewers can compare the same state. If the change has no
visual effect, say so explicitly in the test notes.

## Local commit guard (opt-in)

A pre-commit hook rejects accidental Finder/Xcode "Duplicate" files (`Foo 2.swift`, `Bar copy.metal` — this repo has been bitten by exactly that). Enable it once per clone:
```sh
git config core.hooksPath .githooks
```
Bypass a single commit with `git commit --no-verify`.
