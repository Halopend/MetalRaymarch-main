# Legacy / Cruft Cut List (focused on another 4k–5k LOC)

Scope requested:
- **Ignore Buddhabrot** for this pass.
- **MB3D support can be removed entirely**.
- Prefer removing legacy compatibility paths even if old settings stop loading.

## Quick read
If you want a fast 4k–5k removal **without touching Buddhabrot**, the biggest wins are:

1. Remove or hard-disable the full animation authoring/playback stack:
   - `Threshold/Animation/AnimationViews.swift` (2,077)
   - `Threshold/Animation/AnimationTypes.swift` (1,189)
   - `Threshold/Animation/AnimationManager.swift` (1,144)
   - **Subtotal: 4,410 LOC**

2. Then remove MB3D remnants:
   - `Threshold/Utilities/MB3DImporter/*` (currently stubbed, 20 LOC)
   - `Threshold.xcodeproj/project.pbxproj` MB3D exception entry
   - **Subtotal: small LOC, but deletes dead feature surface completely**

Animation stack removal alone already lands in your requested band.

---

## Concrete deletion bundles (excluding Buddhabrot)

### Bundle A — Animation legacy purge (target ~4.4k)
- Delete:
  - `Threshold/Animation/AnimationViews.swift` (2,077)
  - `Threshold/Animation/AnimationTypes.swift` (1,189)
  - `Threshold/Animation/AnimationManager.swift` (1,144)
- Expected removal: **~4,410 LOC**
- Why this is legacy-heavy:
  - `AnimationTypes` has explicit backward-compat decode logic, legacy track fields, old Spotify fallback synthesis, and round-trip safety fields.

### Bundle B — Audio service abstraction + fallback stack (target ~4.2k with A-lite)
If you want to preserve *some* animation but still nuke legacy complexity:
- Delete (audio stack):
  - `Threshold/Audio/MusicTabView.swift` (1,169)
  - `Threshold/Audio/MusicReactiveTypes.swift` (596)
  - `Threshold/Audio/MusicLibraryWindow.swift` (407)
  - `Threshold/Audio/MusicService.swift` (409)
  - `Threshold/Audio/MusicServiceProtocol.swift` (221)
  - `Threshold/Audio/AppleMusicManager.swift` (442)
  - Audio subtotal: **3,244 LOC**
- Plus one animation core file:
  - `Threshold/Animation/AnimationTypes.swift` (1,189)
- Expected removal: **~4,433 LOC**

### Bundle C — Settings compatibility amputation (target ~4.3k)
- Delete or radically rewrite down to strict v2-only schema:
  - `Threshold/Parameters/RenderSettings.swift` (2,756)
  - `Threshold/Parameters/FractalPreset.swift` (566)
  - `Threshold/Parameters/GradientColorSystem.swift` (405)
  - `Threshold/App/LightingTypes.swift` (425)
- Plus either:
  - `Threshold/Animation/AnimationManager.swift` (1,144) **or**
  - `Threshold/Audio/MusicReactiveTypes.swift` (596) + `Threshold/Audio/MusicService.swift` (409)
- Expected removal: **~4.1k to ~5.3k LOC**, depending on choice.

---

## MB3D removal checklist (feature truly gone)
Even though importer files are now tiny placeholders, if MB3D is officially dead you can remove all traces:

1. Delete directory:
   - `Threshold/Utilities/MB3DImporter/`
2. Remove project exception/reference:
   - `Threshold.xcodeproj/project.pbxproj` entry for `Utilities/MB3DImporter/mb3d_import_cli.swift`
3. Remove any docs mentioning MB3D migration preservation:
   - e.g. stale notes in `V2_REWRITE_PLAN.md` if you want docs aligned.

This won’t save many LOC now, but it prevents future regression and reduces maintenance surface.

---

## Legacy hotspots worth stripping (high compat density)
If old settings compatibility is intentionally dropped, these are the richest cleanup targets:

1. `Threshold/Animation/AnimationTypes.swift`
   - Backward-compatible `Codable`, legacy trackID/source migration, old format synthesis.
2. `Threshold/Audio/MusicReactiveTypes.swift`
   - Legacy Mandelbox mapping migration + backward-compatible decode defaults.
3. `Threshold/Parameters/RenderSettings.swift`
   - Huge per-key UserDefaults fallback behavior and compatibility shims.
4. `Threshold/Parameters/GradientColorSystem.swift`
   - Explicit old archive decoding (`useGradientColoring` legacy discard path).
5. `Threshold/App/LightingTypes.swift`
   - Decode alias behavior for old key names (e.g. smoothLoop/mirrorLoop behavior).

---

## Suggested order (lowest risk to hit 4k quickly)
1. **Animation stack purge** (4,410 LOC) to immediately hit target.
2. **MB3D trace removal** (small LOC, removes dead feature contract).
3. **Then compatibility shims** in `RenderSettings` and music-reactive decoding if you want another 1k–3k after that.

