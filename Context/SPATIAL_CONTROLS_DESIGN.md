# Planted Spatial Radial Controls

Threshold's visionOS radial controls consume `NavigationHierarchy.application`,
the same platform-neutral tree used by the Mac radial menu, keyboard traversal,
and flat controls. The spatial presentation owns no destination IDs, labels,
ordering, or route taxonomy.

## Interaction contract

- A menu gesture captures the exact world-space center of the hand sample that
  produced it. The menu frame (origin, upright basis, and head-facing normal) is
  immutable until dismissal.
- Later hand samples move a direct cursor through that planted frame. The menu
  never follows the hand and never attaches to the selected fractal or another
  scene object.
- Azimuth selects a sibling. Crossing outward through the current commit radius
  selects a branch or activates a leaf. Crossing inward through the retreat
  radius returns one level.
- The root ring is at 0.19 m and commits at 0.32 m. Descendant targets are at
  0.46 m and commit at 0.54 m. Rendering and cursor motion are capped at 0.58 m,
  keeping the deepest interaction within the intended 1.5–2 ft envelope.
- Angular hysteresis prevents sibling chatter. A gaze-provided candidate may
  break a tie only near the boundary between adjacent hand-selected sectors; it
  can never commit a target or override unambiguous hand direction.
- Losing hand tracking hides the cursor while leaving the planted menu fixed.
  Reacquisition rearms radius crossings so a tracking jump cannot activate or
  retreat accidentally.
- While the menu owns input, scene-changing and per-finger shortcut gestures are
  suppressed. The dedicated recovery/menu gesture remains active so the user can
  always dismiss it.

Shape, Render, and Quick Toggles shortcuts focus their existing hierarchy node.
Terminal nodes route through `NavigationStore.activate`, preserving the same
application behavior as every other navigation surface.

## Rendering contract

The active renderer is an instanced Metal pass inside the existing
`LayerRenderer` command buffer. It runs after the raymarch/MetalFX resolve and
before the compositor's required drawable render-context pass. This avoids the
separate `RealityView` sibling that previously delayed first-frame submission
and made immersive startup unreliable.

Cards, depth guides, hub, and direct-hand cursor are world-space quads projected
with the drawable's raw world-to-clip matrices, independent of Threshold's
fractal model transform. Labels come from one lazily-created Core Text atlas;
one shared instance buffer is partitioned by the renderer's in-flight slot.
Resources are initialized only when the already-running immersive renderer first
receives a presentation request.

The dormant `SpatialRadialMenuView` remains source-compatible for reference, but
it is not mounted. The compositor pass is the production spatial presentation.

## Verification

`SpatialRadialNavigationTests` covers canonical branch/leaf routing, focused
presentation, sibling replacement, immutable planting, world/local transforms,
outward traversal, inward retreat, angular hysteresis, gaze tie-breaking,
tracking-loss rearming, reach limits, layout separation, and layout throughput.

The visionOS target compile-checks the compositor integration and Metal shader.
The platform-neutral reducer tests run in the macOS test target.
