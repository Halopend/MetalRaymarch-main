# Threshold — Architecture UML

A UML class-diagram view of the Threshold fractal raymarching app, organized by subsystem.
Diagrams use [Mermaid](https://mermaid.js.org/) and render natively on GitHub.

### Notation legend

| Arrow | UML meaning | Reads as |
|-------|-------------|----------|
| `A *-- B` | composition | A **owns** B (strong, lifetime-bound) |
| `A o-- B` | aggregation | A **holds** B (shared / collection) |
| `A ..> B` | dependency | A **uses / calls** B |
| `B ..\|> A` | realization | B **implements protocol** A |
| `B --\|> A` | inheritance | B **subclasses** A |

Stereotypes (`<<actor>>`, `<<protocol>>`, `<<struct>>`, `<<enum>>`, `<<singleton>>`) mark the Swift kind.

---

## 1. System overview

`AppModel` is the `@MainActor @Observable` hub: it owns every subsystem and wires render-thread
callbacks (`handlers`) into the `Renderer` actor. Data flows **input → parameters → render → UI**.

```mermaid
classDiagram
    direction TB

    class AppModel {
        <<@MainActor @Observable>>
        +renderSettings: RenderSettings
        +parameterPipeline: ParameterPipeline
        +gestureController: GestureController
        +animationManager: AnimationManager
        +musicService: MusicService
        +audioAnalyzer: AudioAnalyzer
        +presetManager: PresetManager
        +clock: AppClock
        +renderMetrics / handTrackingState
        +handlers ..> Renderer
    }

    class Renderer { <<actor>> }
    class RaymarchRenderView { <<SwiftUI bridge>> }
    class ParameterPipeline
    class RenderSettings { <<authoritative state>> }
    class GestureController
    class AnimationManager
    class MusicReactiveEngine
    class AudioAnalyzer
    class MusicService
    class PresetManager
    class AppClock
    class FractalTypeRegistry { <<formulas>> }

    AppModel *-- RenderSettings
    AppModel *-- ParameterPipeline
    AppModel *-- GestureController
    AppModel *-- AnimationManager
    AppModel *-- MusicService
    AppModel *-- AudioAnalyzer
    AppModel *-- PresetManager
    AppModel *-- AppClock
    AppModel ..> Renderer : sets handlers

    RaymarchRenderView ..> AppModel
    RaymarchRenderView *-- Renderer

    GestureController ..> ParameterPipeline : dispatchGesture
    MusicReactiveEngine ..> ParameterPipeline : dispatchAudio
    MusicReactiveEngine ..> AudioAnalyzer : reads bands
    AnimationManager ..> RenderSettings : applyKeyframe (immediate)
    ParameterPipeline ..> RenderSettings : writes (smoothed)
    Renderer ..> RenderSettings : reads per frame
    GestureController ..> FractalTypeRegistry : descriptor lookup
```

**Three platform entry points** each create one `AppModel`:

```mermaid
classDiagram
    direction LR
    class MetalProjectApp { <<visionOS — multi-window + ImmersiveSpace>> }
    class ThresholdMacApp { <<macOS — single window>> }
    class ThresholdiOSApp { <<iOS — inspector layout>> }
    class AppModel
    class ContentView { <<root UI — Fractal/Coloring/Effects/Animate/Gestures/Settings tabs>> }

    MetalProjectApp *-- AppModel
    ThresholdMacApp *-- AppModel
    ThresholdiOSApp *-- AppModel
    MetalProjectApp ..> ContentView
    ThresholdMacApp ..> ContentView
    ThresholdiOSApp ..> ContentView
    ContentView ..> AppModel : @Environment
```

---

## 2. Rendering subsystem

`Renderer` is an `actor` split across many `Renderer*.swift` extensions in `Rendering/Core/`. It runs
on a dedicated thread (`RendererTaskExecutor`) and offloads upscaling to MetalFX. The SwiftUI bridge
(`RaymarchRenderView` + `Coordinator`) connects it to the view hierarchy.

```mermaid
classDiagram
    direction TB

    class RaymarchRenderView { <<NS/UIViewRepresentable>> }
    class Coordinator { <<MTKViewDelegate>> }
    class Renderer {
        <<actor>>
        device, commandQueue
        pipelineCache
        computePipelineCache
        temporalDepthTextures
    }
    class RendererTaskExecutor {
        <<TaskExecutor>>
        dedicated render Thread
    }
    class UIUpdateCoordinator { <<Sendable>> }
    class ParameterUpdateCoordinator { <<Sendable>> }
    class MetalFXManager {
        scalers[] (per eye)
        depthTextures[]
    }
    class MacSpatialUpscaler
    class MacTemporalUpscaler
    class AdaptiveResolutionController
    class BuddhabrotRenderer
    class AppClock { <<pausable time>> }
    class TiltMotionSensor { <<protocol>> }
    class MacMotionSensor
    class IOSTiltMotionSensor

    RaymarchRenderView *-- Coordinator
    Coordinator ..> Renderer
    Coordinator ..> AppModel
    Coordinator ..> TiltMotionSensor

    Renderer *-- UIUpdateCoordinator
    Renderer *-- ParameterUpdateCoordinator
    Renderer ..> RendererTaskExecutor : runs on
    Renderer ..> MetalFXManager
    Renderer ..> AdaptiveResolutionController
    Renderer ..> BuddhabrotRenderer : optional volume path
    Renderer ..> AppClock

    MetalFXManager ..> MacSpatialUpscaler
    MetalFXManager ..> MacTemporalUpscaler
    UIUpdateCoordinator ..> AppModel : batched FPS/metrics
    ParameterUpdateCoordinator ..> AppModel : batched anim/audio

    MacMotionSensor ..|> TiltMotionSensor
    IOSTiltMotionSensor ..|> TiltMotionSensor
```

---

## 3. Parameters & state subsystem

The heart of the app. A **two-path dispatch** model: UI sliders flow through per-parameter
`FloatParameterNode` layer stacks; gesture/audio/animation flow through the
`ParameterOperationDispatcher`'s core/formula stacks. Both resolve into `RenderSettings`, the single
lock-protected authority the renderer reads each frame.

```mermaid
classDiagram
    direction TB

    class ParameterPipeline {
        +dispatchUI()
        +dispatchGesture()
        +dispatchAudio()
    }
    class ParameterOperationDispatcher {
        <<@unchecked Sendable>>
        coreStacks / formulaStacks
        priority conflict resolution
    }
    class ParameterOperation { <<struct>> }
    class ParameterTargetID { <<enum — routing keys>> }

    class ParameterNodeRegistry {
        <<singleton>>
        coreNodes / effectNodes
        formulaBatches
    }
    class AnyParameterNodeBase { <<abstract>> }
    class FloatParameterNode
    class BoolParameterNode
    class ParameterLayerStack {
        <<struct>>
        ui / gesture / system / precompute / music
    }

    class RenderSettings {
        <<@unchecked Sendable>>
        os_unfair_lock
        ~80 live params
    }
    class RenderSettingsSnapshot { <<struct — immutable>> }
    class SettingsPersistence { <<enum — JSON per domain>> }
    class ModuleRegistry { <<enum — preset module routing>> }

    ParameterPipeline *-- ParameterOperationDispatcher
    ParameterOperationDispatcher ..> ParameterOperation
    ParameterOperation ..> ParameterTargetID
    ParameterOperationDispatcher ..> ParameterNodeRegistry : ranges/strategy
    ParameterOperationDispatcher ..> RenderSettings : writes

    FloatParameterNode --|> AnyParameterNodeBase
    BoolParameterNode --|> AnyParameterNodeBase
    ParameterNodeRegistry o-- FloatParameterNode
    ParameterNodeRegistry o-- BoolParameterNode
    FloatParameterNode *-- ParameterLayerStack

    RenderSettings ..> RenderSettingsSnapshot : snapshot per frame
    RenderSettings ..> SettingsPersistence : load/save
    ModuleRegistry ..> RenderSettings : apply module block
```

Config domains are `Codable` value types persisted by `SettingsPersistence`, hydrated into
`RenderSettings`:

```mermaid
classDiagram
    direction LR
    class SettingsPersistence { <<enum>> }
    class GeometryConfig { <<struct>> }
    class ColorConfig { <<struct>> }
    class LightingConfig { <<struct>> }
    class QualityConfig { <<struct>> }
    class DisplayConfig { <<struct>> }
    class AudioReactiveConfig { <<struct>> }
    class GestureConfig { <<struct>> }
    class SafetyBubbleConfig { <<struct>> }

    SettingsPersistence ..> GeometryConfig
    SettingsPersistence ..> ColorConfig
    SettingsPersistence ..> LightingConfig
    SettingsPersistence ..> QualityConfig
    SettingsPersistence ..> DisplayConfig
    SettingsPersistence ..> AudioReactiveConfig
    SettingsPersistence ..> GestureConfig
    SettingsPersistence ..> SafetyBubbleConfig
```

Presets persist a whole scene; v2 adds typed module blocks routed by `ModuleRegistry`:

```mermaid
classDiagram
    direction LR
    class PresetManager { <<@MainActor @Observable>> }
    class FractalPreset { <<struct Codable>> }
    class ModuleParamBlock { <<struct>> }
    class ParamValue { <<enum>> }
    class ICloudBackupManager

    PresetManager o-- FractalPreset
    FractalPreset o-- ModuleParamBlock : modules[ModuleKey]
    ModuleParamBlock o-- ParamValue
    PresetManager ..> ICloudBackupManager
```

---

## 4. Formulas subsystem

A protocol-oriented registry. Each fractal is a `struct` conforming to `FractalTypeDescriptor`;
`FractalTypeRegistry` resolves them by `rawValue`, with a lock-protected overlay for runtime-loaded
custom formulas (`EmbeddedFormula` → `CustomFractalDescriptor`).

```mermaid
classDiagram
    direction TB

    class FractalTypeDescriptor {
        <<protocol Sendable>>
        displayName, icon, category
        defaultFormulaParams()
        gestureRanges / bindings
    }
    class FractalModelType { <<enum Int32>> }
    class FractalTypeRegistry {
        <<static + overlayLock>>
        staticDescriptors
        registerCustom()
    }
    class FormulaCatalog {
        <<singleton @unchecked Sendable>>
        loads catalog.json
    }
    class EmbeddedFormula {
        <<struct Codable>>
        metalSource, params, sourceHash
    }

    class MandelboxDescriptor
    class MandelbulbDescriptor
    class MengerDescriptor
    class KleinianDescriptor
    class QuaternionJuliaDescriptor
    class CustomFractalDescriptor

    MandelboxDescriptor ..|> FractalTypeDescriptor
    MandelbulbDescriptor ..|> FractalTypeDescriptor
    MengerDescriptor ..|> FractalTypeDescriptor
    KleinianDescriptor ..|> FractalTypeDescriptor
    QuaternionJuliaDescriptor ..|> FractalTypeDescriptor
    CustomFractalDescriptor ..|> FractalTypeDescriptor

    FractalTypeRegistry o-- FractalTypeDescriptor
    FractalModelType ..> FractalTypeRegistry : .descriptor
    EmbeddedFormula ..> CustomFractalDescriptor : builds
    CustomFractalDescriptor ..> FractalTypeRegistry : overlay
    FormulaCatalog ..> FractalModelType
```

---

## 5. Gestures subsystem

`GestureController` (`@MainActor`) owns every engine, pulls ARKit hand data each frame, and dispatches
recognized operations to `ParameterPipeline`. `GestureArbitrationEngine` resolves one-hand vs two-hand
conflicts.

```mermaid
classDiagram
    direction TB

    class GestureController { <<@MainActor>> }
    class GestureArbitrationEngine { <<stateless arbiter>> }
    class SingleHandDragEngine
    class TwoHandScalarGestureEngine
    class TwoPointGrabEngine
    class PerFingerTapGestureEngine
    class MenuToggleGestureEngine
    class HandTrackingState { <<@Observable>> }
    class GrabZoomMapping { <<struct>> }
    class GestureSensitivityStore { <<singleton>> }

    GestureController *-- GestureArbitrationEngine
    GestureController *-- SingleHandDragEngine
    GestureController *-- TwoHandScalarGestureEngine
    GestureController *-- TwoPointGrabEngine
    GestureController *-- PerFingerTapGestureEngine
    GestureController *-- MenuToggleGestureEngine
    GestureController ..> HandTrackingState
    GestureController ..> ParameterPipeline : dispatchGesture
    GestureController ..> FractalTypeRegistry : gesture ranges
    GestureController ..> GestureSensitivityStore
    TwoPointGrabEngine *-- GrabZoomMapping
```

---

## 6. Audio & animation subsystems

Music backends sit behind the `MusicServiceProvider` protocol (adapter pattern).
`AudioAnalyzer` does FFT + spectral-flux onset detection; `MusicReactiveEngine` converts band levels
into additive parameter offsets. `AnimationManager` plays keyframed scenes, writing immediate values
into `RenderSettings`. Audio (additive) and animation (base) compose.

```mermaid
classDiagram
    direction TB

    class MusicService { <<@MainActor @Observable — registry>> }
    class MusicServiceProvider { <<protocol>> }
    class AppleMusicServiceAdapter
    class AppleMusicManager { <<MediaPlayer binding>> }
    class AudioAnalyzer { <<FFT + onset>> }
    class SystemAudioTapCapture { <<ScreenCaptureKit, macOS>> }
    class MusicReactiveEngine { <<per-frame band → offset>> }

    class AnimationManager { <<@MainActor @Observable>> }
    class AnimationScene { <<struct Codable>> }
    class AnimationKeyframe { <<struct Codable>> }
    class SongAttachment { <<struct>> }

    MusicService o-- MusicServiceProvider
    AppleMusicServiceAdapter ..|> MusicServiceProvider
    AppleMusicServiceAdapter *-- AppleMusicManager
    SystemAudioTapCapture ..> AudioAnalyzer : ingestExternalBuffer
    MusicReactiveEngine ..> AudioAnalyzer : reads bands
    MusicReactiveEngine ..> ParameterPipeline : dispatchAudio

    AnimationManager o-- AnimationScene
    AnimationScene o-- AnimationKeyframe
    AnimationScene o-- SongAttachment
    AnimationManager ..> RenderSettings : applyKeyframe
    SongAttachment ..> MusicService : play w/ fallback
```

---

## Cross-cutting data flow

```
Input (gesture / tilt / tap)
        │  dispatchGesture
        ▼
ParameterPipeline ──► ParameterOperationDispatcher ──► RenderSettings ◄── reads ── Renderer ──► GPU
        ▲                                                   ▲
        │ dispatchAudio                                     │ applyKeyframe (immediate)
MusicReactiveEngine ◄── bands ── AudioAnalyzer        AnimationManager
        ▲                                                   ▲
   SystemAudioTapCapture / AppleMusicManager           AnimationScene/Keyframe

Renderer ──► UIUpdateCoordinator ──► AppModel.renderMetrics ──► SwiftUI (ContentView)
```
