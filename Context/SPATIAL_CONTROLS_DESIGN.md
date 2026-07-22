# Spatial Controls

Threshold's visionOS controls use the same application navigation tree as the
2-D radial menu, keyboard traversal, and flat controls. The spatial presentation
does not duplicate destination IDs or invent a second information architecture.

## Interaction model

- The existing menu gesture opens a volumetric root ring while immersive space
  is active. Repeating it closes the volume.
- Shape, Render, and Quick Toggles finger shortcuts focus their spatial
  destination directly.
- Gaze targets a glass attachment and pinch confirms it. A two-hand Z-axis
  rotation gesture turns the ring. The center hub moves back one level or closes.
- Branches remain in the volume. Dense terminal destinations reveal the existing
  controls window and activate the same `NavigationHierarchy.Node` route.
- Quick Toggles is a native spatial ring: Bounding Shape, Surroundings,
  Self-Shadows, Smart Advance, and Audio Reactive update the live renderer
  without reconstructing the flat controls.
- Gestures is a native spatial map of the configured per-finger shortcuts. Its
  cards identify hand, finger, and action, then follow the same spatial route as
  the real shortcut.

## Performance contract

- The volume is a separate `RealityView` window; the raymarch compositor loop is
  unchanged.
- Spatial layout has at most nine ordinary navigation attachments. Gesture and
  quick-control modes replace that ring rather than layering another live ring.
- The default volume is 72 x 84 x 24 cm. A full-rotation bounds test covers the
  worst-case ten-card gesture map plus conservative attachment extents.
- Ring placement evaluates four trigonometric functions per update, independent
  of item count, then advances by a complex multiply.
- RealityKit positions are written only when they actually change. Label/status
  invalidations therefore do not fan out into redundant scene-graph transforms.
- There is no display link, timer, or per-frame settings synchronization in the
  spatial controls.
- The one delayed task is a two-second presentation-failure watchdog. It clears
  gesture suppression only if the matching volume request never reaches
  `onAppear`; it performs no recurring work.

`SpatialRadialNavigationTests.layoutThroughput` exercises 20,000 complete
nine-item layouts with a broad 500 ms regression ceiling. On the 2026-07-19
development machine it completed in 36 ms in a Debug test build (~1.8 us per
layout).

## Verification and next depth

Pure tests cover navigation/backtracking, focus semantics, 3-D separation,
rotation rigidity, recurrence accuracy, gesture-map bounds, and layout
throughput. The feature is compile-checked on
visionOS, while shared model changes are built on macOS and iPadOS.

The next depth is direct spatial scalar editing. It should project the existing
`RadialSliderBinding` model into a bounded 3-D slider/knob attachment rather than
adding new render-setting closures to the visionOS view. On-device validation
must tune angular target spacing, window depth, and comfortable reach before
that presentation replaces any dense terminal panels.
