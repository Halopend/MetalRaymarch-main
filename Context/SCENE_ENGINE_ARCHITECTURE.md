# Scene evaluation and rendering boundaries

The raymarch backends consume `EvaluatedSceneFrame` values. `AppModel` owns one
`SceneFrameEvaluator` per session, so opening another viewport does not create
another music oscillator or advance the animation twice for the same timestamp.

## Frame flow

1. A platform renderer submits a monotonic timestamp, immersion mode, and optional
   finger levels. Camera/input adapters still write their targets to `RenderSettings`.
2. `App/SceneFrameCoordinator` coalesces requests, refreshes `AudioHub`, and supplies
   an immutable audio snapshot plus the animation adapter to the evaluator.
3. Under one scene transaction, the evaluator resets outgoing-scene history when
   needed, deposits music offsets, advances animation, interpolates manual targets,
   and updates scene transitions. It captures settings, playback status and time
   together after those operations finish.
4. Renderers use the last completed frame. The viewport uses that same settings
   snapshot for resolution, post-processing, specialization and uniforms. Immersive
   presentation/tracking and platform-specific GPU passes remain in their backend.

Requests use monotonic time, not renderer callback count. Duplicate or backwards
clock samples do not advance animation. The transport receives actual elapsed time;
interpolation and music integrators cap a single step at 1/15 second to avoid a
large discontinuity after a stall. App deactivation resets the evaluation clock.
A committed replacement invalidates the old completed frame, allowing a complete
snapshot of the newly loaded state until its first evaluation finishes.

Headless benchmarks explicitly capture the freshly supplied settings, without
waiting for an application run loop. Quick Look continues to render a static scene
through its headless backend and the shared uniform builder.

## State ownership and locking

`RenderSettings.withSceneTransaction` is the synchronous mutation boundary.
Its recursive lock lets existing property accessors participate in a larger
atomic operation. `withPersistenceSuppressed` uses the same boundary so another
thread's user edit cannot accidentally inherit a scene load's persistence origin.
`withSceneReplacement` adds a monotonically increasing generation token, including
nested preset/scene-state restores. The token is for invalidation, not arithmetic.

Static scene loading commits the preset, parameter reset, gesture overrides and
transition setup together. Animation playback restores its complete initial state
before requesting pipeline prewarming. Keyframe application is persistence-suppressed
and transactional. File IO, asynchronous compilation and service refresh belong
outside these mutation scopes.

Lock order is settings transaction, then parameter-pipeline state. Pipeline reads,
resolution and writes stay in the same transaction. Layer history is invalidated
when its scene generation changes, including when a new UI input arrives before
the next evaluator tick.

## Parameter composition and interface projections

`ParameterPipeline` owns formula and core layer history. UI formula nodes are
metadata/projections and no longer keep independent stacks. Within a transaction,
latest operations are selected per source and applied in deterministic source
order: gesture, slider, then additive music. A slider takes manual ownership from
a prior gesture. Final values are clamped by the target's range.

During animation, manual bases are stored as offsets from the animated base and
music is stored separately. Formula overrides never include the audio offset a
second time. Animated glow, bloom, fog, saturation, hue and fractal scale use the
same manual-offset policy. Existing interaction-release decay remains in force;
manual adjustments are not permanently written into animation keyframes.

`RenderParameterCatalog` owns engine bindings and music metadata with no UI or
navigation dependency. `ParameterCatalog` adds UI and navigation facets using those
same bindings. Quick Look links the real runtime catalog; it no longer substitutes
an empty catalog which silently ignored runtime writes. The pure motion-strategy
enum also comes from the shared control definitions rather than a preview copy.

Simplified controls should project these stable parameter IDs and runtime bindings.
This refactor preserves the existing interface; it does not introduce new macro
controls or change the scene file format.

## Remaining boundaries and verification

The evaluator currently runs on the main actor because `AudioHub` and
`AnimationManager` are app-service adapters. Render requests do not synchronously
wait for a fresh main-actor evaluation, but a busy UI can delay publication and
settings readers can briefly contend with a transaction. Moving transport sampling
and audio-envelope advancement to a dedicated simulation executor is a subsequent
change, not a performance claim made by this refactor.

This is an incremental engine boundary, not yet a standalone library target.
Render backends still use `AppModel` for lifecycle, diagnostics and shader activation;
`RenderSettings` still carries preference adapters. Quick Look retains UI-only
gesture/export stubs. Those are separate from its now-real runtime parameter table.

`SceneFrameEvaluatorTests` covers coherent snapshots, monotonic time, request
coalescing, source shutdown and scene-history invalidation. `AtomicSceneStateTests`
exercises concurrent multi-property writes and snapshot reads.
`ParameterCompositionTests` covers shared UI/music layers, manual ownership,
playback composition and runtime-catalog coverage. Existing scene, keyframe,
parameter, shader and Quick Look gates remain required.

The new lock scope and main-actor work must be measured on Vision Pro before making
frame-time claims. Mac tests and generic-device builds establish correctness and
compilation, not headset performance or perceptual audio latency.
