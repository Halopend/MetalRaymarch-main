# Threshold Quick Look Extensions

Two macOS app extensions that give Threshold documents live, GPU-rendered
Quick Look thumbnails (Finder) and previews (spacebar):

| Target | Kind | Principal class |
|---|---|---|
| `ThresholdQLThumbnail` | `com.apple.quicklook.thumbnail` | `ThumbnailProvider` (`QLThumbnailProvider`) |
| `ThresholdQLPreview` | `com.apple.quicklook.preview` | `PreviewViewController` (`QLPreviewingController`) |

Both are embedded in the **ThresholdMac** host app ("Embed App Extensions" phase)
and are sandboxed (`com.apple.security.app-sandbox`, read-only user-selected files).

## What it renders

Handles all five document UTIs (declared in `Threshold/App/Info.plist`):

| Ext | UTI | Behavior |
|---|---|---|
| `.threshscene` | `…threshold.scene` | **Live render** (built-in **and** embedded-DE); preview is **interactive** (drag = orbit, scroll = zoom) |
| `.threshmp` | `…threshold.music-preset` | **Live render** (built-in + embedded-DE) + interactive |
| `.threshanim` | `…threshold.animation` | Info card (live keyframe render = M3) |
| `.threshanimv` | `…threshold.music-animation` | Info card (M3) |
| `.threshfx` | `…threshold.formula` | Info card (embedded-Metal render = M3) |

Fallback order for scenes: **live render → embedded `thumbnailData` PNG →
branded info card**, so a preview is never blank.

## How the live render works

`ThresholdPreviewRender.image(for:pixelSize:)` dispatches by extension.
`HeadlessRenderer` reproduces the app's Mac screenshot path **headlessly** (no
app, no `MTKView`, no run loop):

```
decode FractalPreset → RenderSettings() → preset.apply(to:) → settings.snapshot()
  → packUniforms()  (faithful mirror of makeUniforms in RaymarchRenderView.swift)
  → draw a radius-100 proxy ellipsoid with screenshotVertexShader / fragmentShaderMono
  → read back BGRA → CGImage
```

`Shaders.metal` is a **member of each extension target**, so Xcode compiles it
into the appex's own `default.metallib` — identical GPU code to the app, loaded
via `makeDefaultLibrary(bundle:)`.

### Embedded distance estimators (custom `.threshscene` DEs)

Scenes whose `fractalType == .custom` carry an `embeddedFormula` with Metal DE
source. For those, `HeadlessRenderer` calls the app's `CustomShaderCompiler`
(`synthesizeSource` — bundled shader strings from `EmbeddedMetalSources` + the
scene's DE spliced at the dispatch markers) and `device.makeLibrary(source:)`,
then builds a pipeline on the same `screenshotVertexShader` /
`fragmentShaderMono` entry points. Compiled pipelines are **cached by
`EmbeddedFormula.sourceHash`** so the interactive view never recompiles per
frame; the preview pre-warms the compile off the main thread before the first
frame. Compilation of the combined source takes **~6–7 s once per scene** (then
cached) — fine for a preview, borderline for a first-time thumbnail (the OS
caches the resulting image afterward).

## Interactive preview

The spacebar preview (`PreviewViewController`) installs a live
`InteractiveFractalView` (an `MTKView`) for fractal scenes:

- **drag** → orbit (yaw/pitch composed on top of the scene's authored rotation)
- **scroll** → zoom (model scale, matching the app's desktop-zoom semantics)

It keeps the scene's `RenderSettings`, mutates `worldRotation`/`scale` on input,
and re-renders on demand (`isPaused` + `enableSetNeedsDisplay`, so idle = free)
via `HeadlessRenderer.render(snapshot:in:)`. Non-scene documents and any
render/decode failure fall back to a static image.

> Interactivity requires the macOS Quick Look panel to forward mouse events to
> the extension's view — verify in Finder once the host app is installed. The
> thumbnail is always a static image.

## Source layout

- `Shared/HeadlessRenderer.swift` — offscreen Metal renderer + `packUniforms`;
  also renders live into an `MTKView` (`render(snapshot:in:)`).
- `Shared/ThresholdPreviewRender.swift` — dispatch facade + info-card fallback.
- `Shared/RenderKitStubs.swift` — small typed stand-ins (see "Reused app source").
- `Preview/InteractiveFractalView.swift` — the draggable live view.
- `Thumbnail/`, `Preview/` — the two providers + their `Info.plist` + entitlements.

## Reused app source (the important maintenance note)

Rather than duplicate Threshold's data + color pipeline (drift risk), the
extension targets include **the app's real source files** as explicit
`SOURCE_ROOT` file references — 33 files spanning `Parameters/`, `App/`,
`Rendering/Core/`, `Gestures/`, `Audio/`, `Formulas/EmbeddedFormula.swift`.
The exact list lives in `wire_quicklook.rb` (`SHARED_SOURCES`).

A handful of those files transitively reference app/UI types
(`ParameterCatalog`, `ParameterNodeRegistry`, `PresetManager`,
`UISettingsCache`, `PerFingerTapGestureEngine`) that pull in SwiftUI /
`AppModel`. Those code paths (`audioModulate`, `bindableActions`,
startup-routing validation) are **never executed by the still-frame render
path**, so `RenderKitStubs.swift` provides empty, correctly-typed stand-ins to
satisfy the type checker. **If the app ever makes `snapshot()` / `apply(to:)`
call into those paths, revisit the stubs.**

> The project uses Xcode-16 synchronized folder groups, which are all-or-exclude
> — you can't add a *subset* of the `Threshold/` folder to another target via a
> sync group. Hence the explicit file references.

## Re-running the wiring

The two targets were created with `wire_quicklook.rb` (needs the `xcodeproj`
gem). It's idempotent-guarded; re-create with:

```
gem install --user-install xcodeproj
GEM_HOME=$HOME/.gem FORCE=1 ruby ThresholdQuickLook/wire_quicklook.rb Threshold.xcodeproj
```

Build/verify a target (signing off):

```
xcodebuild -project Threshold.xcodeproj -target ThresholdQLThumbnail \
  -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Quick Look selection (critical — UTI conformance)

For the appex to be invoked at all, the file's type must NOT conform to
`public.text`. The exported UTIs in `Threshold/App/Info.plist` (+ the Mac/iOS
plists) originally conformed to `public.json` → which conforms to `public.text`
→ so macOS's built-in **text** thumbnailer claimed the file and won over this
appex (proven with qlmanage: the thumbnail was the raw JSON text, byte-identical
to a `.json` copy). Fixed by declaring `public.content` + `public.data` instead
of `public.json` for all five types.

Caveat: LaunchServices **unions** exported-type conformance across every
registered build of the app. On a dev machine with old Threshold builds
(archives, DerivedData, simulators) still declaring `public.json`, the
`public.text` conformance — and the text-handler hijack — persists until those
are gone. Verify on a clean install, or prune stale registrations first:
`lsregister -u <old Threshold.app>` for each, then `qlmanage -r cache`.

## Regression test

`Scripts/ql_render_check.sh` compiles the appex's EXACT source closure (derived
from `wire_quicklook.rb`, so it can't drift) plus `Tests/RenderCheckMain.swift`
and a metallib, then renders every bundled scene through the real
`HeadlessRenderer` (including the runtime embedded-DE compile). It asserts all
scenes render non-nil and that the empirical 17-scene well-framed allowlist
renders non-black (mean luminance > 12); exits non-zero on any regression. Built
`-Onone`. Run it before shipping render changes: `bash Scripts/ql_render_check.sh`.

Note on `RenderKitStubs`: `ParameterCatalog.byID` IS read during render
(`RenderSettings.audioModulate` runs inside `preset.apply(to:)` for music-mapped
scenes); the empty stub makes that a correct no-op for a still frame. The stubs
are *exercised-but-benign*, so the render-check tool — not a per-stub tripwire —
is the divergence guard.

## Known limitations / next steps

- **Authored-camera framing.** Some scenes render black or extreme close-up
  because their authored camera assumes gesture navigation from that start
  point against a fixed eye at z = −3 (see the app's `mac-detailscale`
  behavior). In the **interactive** preview the user can drag/zoom to find the
  fractal; **static thumbnails** of such scenes look bad. A future pass could
  auto-frame (dolly the eye back / reset detailScale) for thumbnails.
- **Animations / `.threshfx`** still show info cards; live keyframe / standalone
  formula render is the remaining piece.
- **Buddhabrot** uses a separate compute path (`BuddhabrotShaders.metal`), not
  bundled here → falls back.
- `[FormulaCatalog] catalog.json not found in bundle` is logged harmlessly —
  built-in fractals don't need it. Ship `catalog.json` as an appex resource to
  silence it (needed if M3 adds catalog-driven formulas).
- Buddhabrot uses a separate compute path (`BuddhabrotShaders.metal`), not
  bundled here → falls back.
