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
- `Collaboration`
- `Analytics`
- `Audio`
- `Animation`
- `Views`
- `Spotify`
- *(feature files are now grouped; root is mostly folder-only)*

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
- `Utilities` (especially `Math`, `Debug`)
- `Scenes`

### 2) Remaining structural opportunities
Most low-risk feature grouping is complete. Remaining optional parity work is primarily:
- **Utilities split:** carve `Utilities/Math` and `Utilities/Debug` from shared helper files if desired.
- **Scenes domain:** formalize a `Scenes/` module if scene management grows beyond current scope.
- **Spotify vs Audio boundary:** decide whether to keep `Spotify/` standalone or fold under `Audio/`.

### 3) Naming mismatch for collaboration domain
- Reference uses `Collaboration/`.
- Target now uses `Collaboration/` for SharePlay-related files.

## Recommended Structural Mapping (Reference -> Target)

- `Analytics/*` -> completed.
- `Audio/*` -> completed.
- `Animation/*` -> completed.
- `Collaboration/*` -> completed.
- `Views/*` -> completed.
- `Utilities/Math/*` -> keep/expand `Rendering/Core/RendererMath.swift` or relocate to `Utilities/Math/` if shared by non-render code.
- `Utilities/Debug/*` -> create `Utilities/Debug/` for perf HUD/debug overlays if introduced.

## Low-Risk Next Moves (Structure-Only)

1. Optional: introduce `Utilities/Math` and `Utilities/Debug` if cross-domain helper sharing grows.
2. Optional: evaluate `Scenes/` module boundary for future scene system expansion.
3. Keep `Rendering/Core` as-is (already aligned with reference intent).

## Risk Notes

- These are mostly **path/import churn** changes; runtime behavior risk is low when done in small batches.
- The highest regression risk remains in renderer symbols; those should stay stable while doing folder-only moves.
- Continue validating with `xcodebuild` after each batch.

## Current Build Status

- Target project currently builds successfully on `visionOS Simulator`.
- Existing unrelated warning persists in `SpotifyAuthManager.swift` (placeholder client ID warning).
