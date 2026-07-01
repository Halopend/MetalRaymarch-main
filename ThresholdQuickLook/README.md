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

## Known limitations / Milestone 3

- **Custom-formula scenes** (`fractalType == .custom` or `embeddedFormula != nil`)
  need runtime Metal compilation (`CustomShaderCompiler`) — currently fall back
  to the baked PNG. Live compile is M3.
- **Animations / `.threshfx`** show info cards; live keyframe / formula render is M3.
- `[FormulaCatalog] catalog.json not found in bundle` is logged harmlessly —
  built-in fractals don't need it. Ship `catalog.json` as an appex resource to
  silence it (needed if M3 adds catalog-driven formulas).
- Buddhabrot uses a separate compute path (`BuddhabrotShaders.metal`), not
  bundled here → falls back.
