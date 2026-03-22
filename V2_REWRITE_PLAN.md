# Threshold V2 Rewrite Plan

## Goal

Rebuild the app around one source of truth for fractal parameters, one parameter
resolution pipeline, and one compiler step from app state to GPU state.

The current codebase mixes:

- catalog-backed formula metadata
- hardcoded descriptor defaults
- dedicated Mandelbox geometry fields
- generic `formulaParams`
- gesture target fields
- animation offsets
- GPU uniform packing

That makes it hard to reason about correctness and creates bridge code.

## Core Principles

1. Schema-first.
Every fractal declares its parameters, defaults, ranges, UI groups, and GPU slot
mapping in one manifest.

2. Canonical state first, derived GPU state second.
App systems edit canonical scene state. A compiler produces Metal packets.

3. Parameter changes are unified.
UI, gestures, audio, animation, preset loads, and imports all emit the same
change model.

4. Fractals are plugins.
Each fractal owns its schema, its DE/orbit implementation, and any special GPU
compile hints.

5. Typed app model, packed GPU model.
Named and typed parameters in Swift. Packed slot arrays only at the compiler
boundary.

## Proposed Top-Level Layout

```text
ThresholdV2/
  App/
    ThresholdV2App.swift
    AppComposition.swift
    AppEnvironment.swift
    Navigation/
    Commands/

  Domain/
    Scene/
      SceneDocument.swift
      SceneIdentity.swift
      SceneMetadata.swift
    Camera/
      CameraState.swift
      ViewTransform.swift
    Fractals/
      FractalType.swift
      FractalInstance.swift
      FractalSchema.swift
      FractalParameterID.swift
      FractalParameterValue.swift
      FractalParameterDefinition.swift
      FractalParameterStore.swift
    Effects/
      EffectStack.swift
      EffectState.swift
      ColorState.swift
    Interaction/
      GestureBinding.swift
      InteractionState.swift
    Timeline/
      AnimationTrack.swift
      Keyframe.swift
      PlaybackState.swift
    Audio/
      AudioModulationState.swift
      AudioAnalysisFrame.swift

  Engine/
    Parameters/
      ParameterChange.swift
      ParameterSource.swift
      ParameterResolver.swift
      ParameterLayerState.swift
      ResolvedSceneState.swift
    Compiler/
      SceneCompiler.swift
      GPUScenePacket.swift
      GPUCameraPacket.swift
      GPUFractalPacket.swift
      GPUEffectPacket.swift
      FractalPacketEncoder.swift
    Renderer/
      RendererCoordinator.swift
      RenderLoop.swift
      FrameScheduler.swift
      PipelineLibrary.swift
      RenderPasses/
    Interaction/
      GestureEngine.swift
      HitTesting.swift
      ManipulatorMath.swift
    Animation/
      AnimationEngine.swift
      TrackEvaluator.swift
    Audio/
      AudioEngine.swift
      AudioModulationEngine.swift

  FormulaModules/
    Mandelbox/
      MandelboxModule.swift
      MandelboxSchema.swift
      MandelboxCompiler.swift
      MandelboxShaders.metal
    Mandelbulb/
      MandelbulbModule.swift
      MandelbulbSchema.swift
      MandelbulbCompiler.swift
      MandelbulbShaders.metal
    Kleinian/
    QuaternionJulia/
    ...

  Persistence/
    SceneStore.swift
    PresetStore.swift
    Migration/
      LegacySceneImporter.swift
      LegacyPresetImporter.swift
      CatalogImporter.swift

  UI/
    SceneEditor/
    FormulaEditor/
    EffectsEditor/
    TimelineEditor/
    AudioEditor/
    Shared/

  Support/
    Logging/
    Diagnostics/
    Math/
    Extensions/

  Tests/
    DomainTests/
    CompilerTests/
    FormulaModuleTests/
    RendererTests/
    SnapshotTests/
```

## What Each Layer Owns

### `Domain`

Pure app state. No Metal types, no UI framework assumptions, no smoothing logic.

- `SceneDocument`: the saved/opened document.
- `FractalInstance`: active fractal type plus its typed parameter store.
- `FractalSchema`: parameter metadata and semantic meaning.
- `EffectStack`: color and post-processing authoring state.
- `InteractionState`: gesture selection, bindings, and editing context.
- `PlaybackState`: animation and transport state.

### `Engine/Parameters`

The only place where parameter precedence and modulation rules live.

- `ParameterChange`:
  - target parameter id
  - source (`ui`, `gesture`, `animation`, `audio`, `preset`, `import`)
  - operation (`set`, `add`, `multiply`, `toggle`)
  - value payload
  - timestamp/frame index
  - smoothing policy
- `ParameterResolver`:
  - applies changes
  - resolves precedence
  - computes smoothed values
  - outputs `ResolvedSceneState`

This replaces ad hoc bridging between node stacks, target values, animation base
values, and special-case renderer fields.

### `Engine/Compiler`

Pure translation from resolved app state into GPU packets.

- `SceneCompiler` takes:
  - `SceneDocument`
  - `ResolvedSceneState`
  - active `FractalModule`
- returns:
  - `GPUScenePacket`
  - optional function-constant selections
  - precomputed derived values

This is the only place where named parameter values become packed arrays like
`params[16]`.

### `FormulaModules`

Each module owns one fractal end-to-end.

- schema
- default values
- validation rules
- packet encoding for GPU
- shader entry points
- optional import/export helpers

There should be no fractal-specific logic scattered through unrelated systems.

## Core Runtime Types

### `FractalSchema`

```swift
struct FractalSchema: Sendable {
    let type: FractalType
    let displayName: String
    let groups: [ParameterGroup]
    let parameters: [FractalParameterDefinition]
    let gpuLayout: GPUParameterLayout
}
```

### `FractalParameterDefinition`

```swift
struct FractalParameterDefinition: Sendable, Identifiable {
    let id: FractalParameterID
    let label: String
    let kind: ParameterKind
    let domain: ParameterDomain
    let defaultValue: FractalParameterValue
    let ui: ParameterUIPolicy
    let modulation: ParameterModulationPolicy
    let gpuBinding: GPUParameterBinding
}
```

### `FractalParameterStore`

Typed store keyed by semantic ids, not raw indices.

```swift
struct FractalParameterStore: Sendable {
    private var values: [FractalParameterID: FractalParameterValue]
}
```

### `ResolvedSceneState`

The renderer never pulls from authoring state directly.

```swift
struct ResolvedSceneState: Sendable {
    let camera: CameraState
    let fractal: ResolvedFractalState
    let effects: EffectState
    let interaction: InteractionState
    let timing: FrameTimingState
}
```

## How Mandelbox Should Work In V2

Mandelbox should stop being special in app state.

Today it effectively has two models:

- dedicated fields: `minDistance`, `foldingLimit`, `sphereRadius`
- generic `formulaParams[0...2]`

In V2 it has one schema:

- `mandelbox.minDistance`
- `mandelbox.foldingLimit`
- `mandelbox.sphereRadius`

Then the compiler decides how to encode those values for Metal:

- as dedicated uniform fields if the shader wants them
- as packed parameter slots if a generic kernel wants them

The state model does not care.

## UI Model

The UI should be generated from schema metadata, not from hand-built node
registries.

### Generated editors

- scalar slider / scrubber
- toggle
- vector control
- grouped section panels
- gesture binding picker
- audio modulation picker

### UI-specific rules come from `ParameterUIPolicy`

- slider range
- fine/coarse step
- icon
- group
- visibility
- whether gesture binding is allowed
- whether audio modulation is allowed

## Renderer Model

### Keep the renderer thin

The renderer should do four things:

1. accept compiled GPU packets
2. manage Metal resources and pipelines
3. schedule render passes
4. return frame outputs and diagnostics

It should not:

- own business defaults
- decode user gesture semantics
- know preset migration rules
- reach into raw app settings to interpret fractal parameters

## Suggested Module Interfaces

### `FractalModule`

```swift
protocol FractalModule: Sendable {
    var schema: FractalSchema { get }
    func makeDefaultStore() -> FractalParameterStore
    func validate(_ store: inout FractalParameterStore)
    func compile(
        resolved: ResolvedFractalState,
        context: CompileContext
    ) -> GPUFractalPacket
}
```

### `SceneCompiler`

```swift
protocol SceneCompiler: Sendable {
    func compile(
        scene: SceneDocument,
        resolved: ResolvedSceneState,
        module: any FractalModule
    ) -> GPUScenePacket
}
```

### `ParameterResolver`

```swift
protocol ParameterResolving: Sendable {
    mutating func apply(_ changes: [ParameterChange])
    mutating func resolve(at time: TimeInterval) -> ResolvedSceneState
}
```

## Presets, Scenes, and Import/Export

### Save semantic values, not GPU packets

Persist:

- fractal type
- parameter ids and values
- camera state
- effect stack
- animation tracks
- gesture bindings
- audio mappings

Do not persist:

- packed GPU arrays
- derived uniforms
- transient smoothing state

### Migration layer

Build importers for:

- current Threshold scene format
- current preset format
- legacy Mandelbox-only presets
- any MB3D mappings you want to preserve

All importers should convert into `SceneDocument`.

## What To Delete From The Current Design

These concepts should not survive into V2 as first-class architecture:

- duplicated formula defaults in descriptors
- app-level dependence on anonymous formula slots
- special Mandelbox bridge from `formulaParams` to dedicated geometry fields
- renderer-owned parameter smoothing policy
- giant global settings object as the main state container
- separate node metadata and formula metadata sources

## Phased Migration Plan

### Phase 1: Build the schema and domain model

- add `FractalSchema`, `FractalParameterDefinition`, and typed stores
- import current `catalog.json` into the new schema format
- encode current formulas as semantic parameter ids

### Phase 2: Build the parameter resolver

- define `ParameterChange`
- unify UI, gesture, audio, and animation updates behind it
- produce `ResolvedSceneState`

### Phase 3: Build the compiler

- compile `ResolvedSceneState` into current Metal uniform layouts
- keep the existing shaders temporarily
- verify identical visuals for one chosen fractal

### Phase 4: Port one fractal module completely

Recommended first port:

- Mandelbulb if you want a clean generic test case
- Mandelbox if you want to kill the hardest special case first

My recommendation: port Mandelbox first, because it forces the architecture to
solve the dedicated-field-vs-packed-param problem correctly.

### Phase 5: Move UI generation onto schema

- formula editor from schema
- gesture binding choices from modulation policy
- audio targets from schema metadata

### Phase 6: Migrate persistence

- `SceneDocument` becomes canonical
- import legacy data into the new model
- stop writing old formats once parity is reached

### Phase 7: Shrink the old renderer surface

- stop reading app settings directly from render code
- accept only compiled packets
- delete bridge fields and duplicate defaults

## Immediate First Slice

If starting tomorrow, I would do this exact slice:

1. Create `FractalSchema`, `FractalParameterDefinition`, `FractalParameterStore`.
2. Write a `CatalogSchemaAdapter` that converts the current formula catalog.
3. Implement `MandelboxModule` with semantic ids.
4. Implement `SceneCompiler` for Mandelbox only.
5. Feed the existing renderer with compiled packets from the new compiler.
6. Verify rendered parity with the current app on a small preset set.

That gives you a working vertical slice without rewriting the whole app at once.

## Success Criteria

You know the rewrite is on the right track when:

- adding a parameter only changes one schema definition
- presets save semantic ids, not raw slot assumptions
- the renderer never needs to know where a parameter came from
- Mandelbox no longer needs bridge code in app state
- gesture/audio/animation all target the same parameter API
- Metal packet generation is deterministic and easy to inspect in tests

## Final Recommendation

Do not frame V2 as "a nicer renderer."
Frame it as "a compiled fractal scene engine."

That is the architecture that removes the current failure mode: too many paths
trying to describe the same fractal parameters.
