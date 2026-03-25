# Legacy / Fractured Code Cut List (excluding root `Sources/`)

This is a brutal shortlist of the next deletions for a **20% LOC reduction**.

## Current baseline
- Approx code lines scanned (Swift/Metal/C-family, excluding `Sources/`, assets, xcodeproj): **38,314**.
- 20% target from this baseline: remove **~7,663** lines.
- This change set already removed: **1,192** lines.
- Remaining to hit 20% target: **~6,471** lines.

## Biggest remaining deletion targets
1. `Threshold/Animation/AnimationViews.swift` (~2,077)
2. `Threshold/Animation/AnimationTypes.swift` (~1,189)
3. `Threshold/Animation/AnimationManager.swift` (~1,144)
4. `Threshold/Formulas/Buddhabrot/BuddhabrotRenderer.swift` (~1,392)
5. `Threshold/Formulas/Buddhabrot/BuddhabrotShaders.metal` (~1,011)
6. `Threshold/Audio/MusicTabView.swift` (~1,169)

Combined removal of Animation + Buddhabrot alone is roughly **6,813 lines**, which would nearly close the remaining gap by itself.

## Legacy marker hotspots (textual indicators)
High legacy/backward-compat concentration remains in:
- `Threshold/Animation/AnimationTypes.swift`
- `Threshold/Rendering/Renderer.swift`
- `Threshold/App/LightingTypes.swift`
- `Threshold/App/FractalModelType.swift`
- `Threshold/Parameters/RenderSettings.swift`

## Recommended “break-it-to-simplify” migration order
1. Drop old animation scene formats and keep only one current schema.
2. Remove Buddhabrot pipeline if not a top-tier formula path.
3. Remove SharePlay/collaboration if usage is low.
4. Collapse music reactive settings into one typed domain and delete per-key fallback logic.
5. Remove all raw-value enum decode fallbacks and legacy key aliasing.
