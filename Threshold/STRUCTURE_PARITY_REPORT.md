# Structure Parity Report

## Scope
This report compares:
- **Reference:** `Threshold/Threshold/Threshold`
- **Target:** `MetalRaymarch-main/Threshold`

Goal: reflect more of the reference project’s feature-oriented structure while preserving current behavior and performance systems.

## Top-Level Folder Parity

### Reference folders
- `App`
- `Rendering`
- `Parameters`
- `Gestures`
- `Audio`
- `Animation`
- `Collaboration`
- `Analytics`
- `Utilities`
- `Views`
- `Scenes`

### Target folders (current)
- `App`
- `Rendering` (`Core` extracted)
- `Parameters`
- `Gestures`
- `SharePlay`
- `Spotify`
- *(many feature files still at project root)*

## Current Alignment (What Already Matches)

- **App:**
  - Reference: `App/AppModel.swift`, `App/AppConfiguration.swift`
  - Target: `AppModel.swift`, `App/AppClock.swift`

- **Rendering/Core modularization:**
  - Reference has core rendering services split into focused files.
  - Target now has split renderer extensions in `Rendering/Core/`:
    - `RendererCoreTypes.swift`
    - `RendererPipelineHelpers.swift`
    - `RendererPipelineCache.swift`
    - `RendererPrecomputeHelpers.swift`
    - `RendererGameState.swift`
    - `RendererDynamicQuality.swift`
    - `RendererFrameLoopHelpers.swift`
    - `RendererRenderSupport.swift`
    - `RendererSetupAndSession.swift`
    - `RendererScreenshot.swift`
    - `RendererLoopSupport.swift`
    - `RendererMath.swift`

- **Parameters / Gestures extraction (started):**
  - `Parameters/RenderSettings.swift`
  - `Parameters/RenderSettingsSnapshot.swift`
  - `Parameters/QualityPreset.swift`
  - `Gestures/MenuToggleGestureMode.swift`

## Structural Gaps vs Reference (High Signal)

### 1) Missing feature folders in target
Reference has explicit feature domains that are not yet represented as folders in target:
- `Analytics`
- `Audio`
- `Animation`
- `Collaboration` (target uses `SharePlay` + root handlers)
- `Utilities` (especially `Math`, `Debug`)
- `Views`
- `Scenes`

### 2) Root-level file concentration in target
The following are still mostly flat at project root and would map naturally to reference-style domains:
- **Animation:** `AnimationManager.swift`, `AnimationTypes.swift`, `AnimationViews.swift`
- **Audio:** `AudioAnalyzer.swift`, `AppleMusicManager.swift`, `MusicTabView.swift`
- **Analytics:** `UsageAnalytics.swift`
- **Views/UI:** `LightingEffectsView.swift`, `GradientEditorView.swift`, `PresetViews.swift`, `RecordingViews.swift`, `ToggleImmersiveSpaceButton.swift`
- **Parameters/services:** `PresetManager.swift`, `ParameterRecorder.swift`, `GradientColorSystem.swift`
- **Rendering wrappers:** `DynamicRenderQualityManager.swift`, `MetalFXManager.swift`

### 3) Naming mismatch for collaboration domain
- Reference uses `Collaboration/`.
- Target currently splits collaboration-related concerns across `SharePlay/` and root app wiring.

## Recommended Structural Mapping (Reference -> Target)

- `Analytics/*` -> create `Analytics/` and move `UsageAnalytics.swift`.
- `Audio/*` -> create `Audio/` and move `AudioAnalyzer.swift`, `AppleMusicManager.swift`, plus audio-reactive orchestration.
- `Animation/*` -> create `Animation/` and move `AnimationManager.swift`, `AnimationTypes.swift`, `ParameterRecorder.swift` (or split recorder into animation domain).
- `Collaboration/*` -> create `Collaboration/` and colocate `SharePlay` wrappers (`FractalShareActivity.swift`, `FractalShareSession.swift`) and sync logic.
- `Views/*` -> create `Views/` and move UI components now at root.
- `Utilities/Math/*` -> keep/expand `Rendering/Core/RendererMath.swift` or relocate to `Utilities/Math/` if shared by non-render code.
- `Utilities/Debug/*` -> create `Utilities/Debug/` for perf HUD/debug overlays if introduced.

## Low-Risk Next Moves (Structure-Only)

1. Create folders and move files without behavior changes:
   - `Analytics/UsageAnalytics.swift`
   - `Animation/{AnimationManager.swift, AnimationTypes.swift, AnimationViews.swift}`
   - `Audio/{AudioAnalyzer.swift, AppleMusicManager.swift, MusicTabView.swift}`
2. Create `Views/` and move view files currently in root.
3. Create `Collaboration/` and move `SharePlay/*` there (or alias folder naming first, then migrate imports).
4. Keep `Rendering/Core` as-is (already aligned with reference intent).

## Risk Notes

- These are mostly **path/import churn** changes; runtime behavior risk is low when done in small batches.
- The highest regression risk remains in renderer symbols; those should stay stable while doing folder-only moves.
- Continue validating with `xcodebuild` after each batch.

## Current Build Status

- Target project currently builds successfully on `visionOS Simulator`.
- Existing unrelated warning persists in `SpotifyAuthManager.swift` (placeholder client ID warning).
