# Threshold UI Audit — Top-Dock Layout

Source of truth for the Figma reconstruction. Captures the structure, design
tokens, and component vocabulary of the **top-dock** interface (the current
primary layout), reconstructed from SwiftUI source.

## Layout skeleton (`ContentView.immersiveLayout`)

```
┌─ menu surface (RoundedRect r=20, dark glass, white .stroke) ──────────────┐
│  [ top-dock ornament ]  ←── pinned top-left, dark capsule bar r=18         │
│  ┌───────────┬──────────────────────────────────────────────────────────┐│
│  │ section   │  content panel  (selected rail section → legacy *Content)  ││
│  │ rail      │                                                            ││
│  │ (w=170    │                                                            ││
│  │  mac /    ├──────────────────────────────────────────────────────────┤│
│  │  208 iOS /│  bottom bar: [activity lights] [Enter/Exit] … [rec][save]  ││
│  │  228 vP)  │                                                            ││
│  └───────────┴──────────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────────────────────────┘
```

Outer surface: `RoundedRectangle(cornerRadius: 20)` + `thresholdGlassBackground`,
1px white-ish stroke. Layout padding: H=12, V=10.

## Navigation taxonomy

Top dock (`TopDockTab`): **Explore · Shape · Visualizations · Music**
Rail sections per dock tab:
- Explore → Jumping Off · Music Reactive · Animated · Custom Scenes
- Shape → Parameters · Formula · Space · Performance
- Visualizations → Color · Mapping · Grading · Cycling · Atmosphere · Transition · Audio Reactive
- Music → Playback(/Music App) · Songs · Playlists · Albums  (macOS: Playback only)

Rail footer: Gestures (if supported) · pinned-control grid (3-col) · Settings.
Rail sections map back onto legacy `selectedTab`/subtab content builders via
`syncNavigationChromeFromLegacySelection` — the dock+rail are pure navigation
chrome; the panels are the legacy `*Content` views.

## Design tokens (`DesignSystem.swift` → `DS`)

Spacing: xxs 4 · xs 6 · sm 8 · md 10 · lg 12 · xl 16 · xxl 20
Radius:  xs 4 · sm 6 · inset 8 · control 10 · card 12 · panel 16 · prominent 20
Tints (opacity over bg): sectionFill .06 · surfaceFill .08 · hoverFill .12 ·
selectedFill .14 · border .12 · strongBorder .4
Semantic: surface = secondary@.08 · border = secondary@.12 · accent = blue

## Component vocabulary (selected → blue accent throughout)

| Component        | Spec |
|------------------|------|
| Dock pill        | Capsule, H14/V10. Selected: blue@.18 fill + blue@.22 stroke, text primary. Else: clear + secondary@.14 stroke, text secondary. Icon 15pt semibold + subheadline-semibold label. |
| Dock ornament    | RoundedRect r=18, black@.82(dark)/.72(light) fill, white@.10 stroke, glass. H14/V10. |
| Rail button      | RoundedRect r=12, H10/V10, full-width leading. Icon 15pt semibold (18pt frame) + footnote-semibold label. Selected blue@.18 fill / blue@.22 stroke; else clear / secondary@.10. |
| Pinned rail btn  | Icon-only, RoundedRect r=10, h=38, 3-col grid. Same selected tinting. |
| Count badge      | Small colored capsule, top-trailing of dock icon (pink=dynamic, green=music). |
| Section header   | `Label(title, systemImage)` headline + optional trailing accessory (e.g. FPS). |
| Sub-section      | VStack spacing 8: title row (Text + Spacer + bold value) then control. |
| Segmented picker | `.pickerStyle(.segmented)` — track r≈8, selected segment raised. |
| Slider row       | Title + Spacer + bold monospaced value, then Slider (track + knob). |
| Preset button    | `.bordered`, VStack icon(caption)+label(caption2), tinted blue when active. |
| Helper caption   | caption2, secondary. Sits under controls. |
| Activity lights  | Capsule bar secondary@.08 / .14 stroke, 4 colored toggle dots (blue/pink/orange/red). |

## Representative panel — Shape ▸ Performance (`fractalQualityContent`)

VStack spacing 12:
1. Header `Label("Performance","gauge")` headline + `FPSIndicatorView` trailing.
2. Renderer Mode: title row (+ bold current value), segmented picker
   (Fragment · Quad Shared · Adaptive Compute), helper caption.
3. Target Condition: title + segmented (Framerate · Detail · Control, maxW 340),
   helper caption.
4. "Iteration Budget" headline.
   - non-Control: row of `QualityPreset` bordered buttons (icon+caption2).
   - Control: slider rows — Fractal Iterations 4…32, plus ray steps etc.

## Figma file
- `Threshold UI — Top-Dock Layout` — key `HZwKuOv80n6a2UOtd49prN`
- https://www.figma.com/design/HZwKuOv80n6a2UOtd49prN
