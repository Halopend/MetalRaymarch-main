# Vertically-Integrated ParameterNode / ParameterCatalog — Final Design

> Goal (user): "simplify this with a class hierarchy of parameternode with different layers
> handling different areas like ui and feature enablement. the more we simplify and contain
> these vertically integrated nodes the more we can simplify the codebase."
>
> Today: adding ONE scalar (e.g. `sphereProjectionBlend`) means editing 6 parallel registries
> kept in lockstep by a runtime tripwire. After: one authored `ParameterDescriptor`; the other
> registries are derived projections or deleted.

---

## 0. The shape of the win

There is already a near-complete single-source-of-truth: `ControlSpec` /
`ControlCatalog` (`Threshold/Parameters/ControlSpec.swift`). `FloatParameterNode(spec:)`
(`ParameterNodeSystem.swift:104-126`) and `CoreParameterDescriptor(spec:)`
(`ParameterOperationSystem.swift:134-141`) both *source* range/default/name/icon/motion from
it, and `MusicReactiveTarget.displayName/icon/allowedRange` already delegate to it
(`MusicReactiveTypes.swift:297,315,334`). What the spec does **not** yet own — and what is
still hand-duplicated per scalar — is exactly four things:

1. the **off-main RenderSettings read/write pair** (lives in `coreDescriptors`, `ParameterOperationSystem.swift:146-202`);
2. the **@MainActor UISettingsCache read/write pair** (lives inline in `buildCoreAndEffectNodes`, `ParameterNodeSystem.swift:397-494`);
3. the **music defaults** — `category/defaultSource/defaultResponseCurve/hasFlashingRisk` (four exhaustive switches, `MusicReactiveTypes.swift:276-414`);
4. the **routing/capability/gesture** classification — `ParameterTargetID.coreAndEffect` (`ParameterTargetID.swift:26-38`), `gestureBindableCoreParameters` hardcoded id list (`ParameterNodeSystem.swift:598`), and the per-fractal `availableCases(for:)` (`MusicReactiveTypes.swift:221`).

The design promotes `ControlSpec` into an authored `ParameterDescriptor` that owns all four,
so those become **derived projections** of `ParameterCatalog`. We deliberately do **not**
merge the two layer stacks or the two read/write pairs into one closure — that is the
genuinely hard concurrency item (the two-stack split, memory `music-param-two-stack-split`);
we only **co-locate** them on one descriptor so they cannot drift, and we keep
`validateStartupRouting` as a real (non-tautological) guard.

---

## 1. Target type hierarchy & what each layer owns

We keep VALUE types for authored metadata (matches the existing `Equatable` `ControlSpec`,
avoids reference/Sendable hazards) and keep the existing node CLASS for live state.

```
ControlSpec  (UNCHANGED, stays Equatable)         // Parameters/ControlSpec.swift
  └─ id, name, icon, range, defaultValue, motionStrategy, clamp()

— NEW authored facets (Sendable value types, NON-Equatable because they hold closures) —

struct MusicFacet: Sendable                        // collapses MusicReactiveTypes switches
  └─ category, defaultSource, defaultResponseCurve, hasFlashingRisk

struct GestureFacet: Sendable
  └─ isMappable: Bool, tripletGroupKey: String?    // tripletGroupKey nil for scalars

enum ParameterCapability: Sendable                 // reuses FractalTypeDescriptor.supports
  └─ .universal | .requires(@Sendable (FractalModelType) -> Bool)
       func isAvailable(_:) -> Bool

struct ParameterRoute: Sendable                    // REUSE Module.swift ModuleRoute {tab,section}
  └─ tab, section, order

struct UIBinding: Sendable                          // @MainActor pair — UI path ONLY
  └─ read:  @MainActor @Sendable (UISettingsCache) -> Float
     write: @MainActor @Sendable (UISettingsCache, Float) -> Void
     persists: Bool

struct SettingsBinding: Sendable                    // off-main pair — dispatcher path ONLY
  └─ read:  @Sendable (RenderSettings) -> Float
     write: @Sendable (RenderSettings, Float) -> Void

struct ParameterDescriptor: Sendable, Identifiable  // the "vertically-integrated node"
  └─ spec: ControlSpec                              // id/range/default/name/icon/motion
     route: ParameterRoute?
     capability: ParameterCapability
     gesture: GestureFacet?
     music: MusicFacet?
     ui: UIBinding                                  // @MainActor closures, never called off-main
     settings: SettingsBinding                      // @Sendable closures, never called on the UI metadata path
     var id: String { spec.id }
     func clamp(_:) -> Float { spec.clamp($0) }

enum ParameterCatalog                               // the SINGLE authored surface
  └─ routedDescriptors: [ParameterDescriptor]       // == the 11 core/effect/space == today's coreAndEffect
     allDescriptors:    [ParameterDescriptor]       // routed + (future) unrouted long-tail
     byID:              [String: ParameterDescriptor]   // over routedDescriptors
     settingsBinding(for id:) -> SettingsBinding?   // NARROWED projection (off-main reads ONLY this)
```

Live node layer (CLASS, **unchanged shape**, `ParameterNodeSystem.swift`):

```
AnyParameterNodeBase  (@unchecked Sendable, immutable metadata)     // UNCHANGED
  ├─ FloatParameterNode  (range + @MainActor ui closures + Mutex<ParameterLayerStack>)
  │     + convenience init(descriptor:)   // pulls EVERY field from a ParameterDescriptor
  └─ BoolParameterNode   (no stack, no range)                       // UNCHANGED
```

**Layer ownership summary:**
- `ParameterDescriptor` (authored) owns: identity, range/default/name/icon/motion (via `spec`), UI placement (`route`), feature enablement (`capability`), gesture binding (`gesture`), music defaults (`music`), and BOTH binding pairs.
- `FloatParameterNode` (live) owns ONLY: its `Mutex<ParameterLayerStack>` (the `.ui` node stack) + the cached @MainActor closures. It is *built from* a descriptor.
- `ParameterOperationDispatcher` keeps its off-main `coreStacks`/`formulaStacks` and reads range/motion/settings-closures **from the descriptor** instead of from its own `coreDescriptors` literal.
- `RenderSettings` / `UISettingsCache` are the authoritative + mirror stores the bindings call into — **unchanged**.

The descriptor is a **non-Codable runtime facade** (exactly like `FractalTypeDescriptor` is a
non-Codable facade over the Codable `FractalModelType` enum). It is never serialized.

---

## 2. Before / After: "add one scalar param"

### TODAY (6 lockstep edits, enforced by a startup precondition)
1. `ParameterTargetID.swift` — add string constant + add it to `coreAndEffect[]` (`:26-38`).
2. `ControlSpec.swift` — add a `ControlSpec` to `ControlCatalog` + to `allSpecs` (`:237-241`).
3. `ParameterOperationSystem.swift` — add a `CoreParameterDescriptor` entry to `coreDescriptors` with the off-main RS read/write pair (`:146-202`).
4. `ParameterNodeSystem.swift` — add a `FloatParameterNode(spec:)` in `buildCoreAndEffectNodes` with the @MainActor cache read/write pair + group + gesture flag (`:397-494`); if gesture-universal, also hand-add the id to `gestureBindableCoreParameters` (`:598`).
5. `MusicReactiveTypes.swift` — add an enum case + arms in `category`, `defaultSource`, `defaultResponseCurve`, `hasFlashingRisk`, `parameterTargetID`, and BOTH `availableCases` lists (`:213-448`).
6. `RenderSettings.swift` — add backing var + clamped persisting setter + `audioModulate<Name>` non-persisting setter (clamp literal copied by hand).

### AFTER (2 edits)
1. **`ParameterCatalog`** (in `ControlSpec.swift`): author ONE `ParameterDescriptor` — spec + route + capability + gesture + music + the two binding pairs. (`routedDescriptors`/`byID`/`coreAndEffect` derive automatically; node, dispatcher descriptor, music defaults, gesture menu all project from it.)
2. **`RenderSettings.swift`**: add backing var + the public persisting setter + the `audioModulate<Name>` setter. (This stays because it is the authoritative lock-protected store; but see §3.6 — the `audioModulate` **clamp** is sourced from `descriptor.clamp`, removing the hand-copied literal.)

The `MusicReactiveTarget` enum still needs a new **case** *only if* the param is music-reactive
(persistence requires a stable rawValue key) — but that case carries NO metadata; all its
switch bodies project from the descriptor. So music adds 1 line (a bare `case`), not 7.

---

## 3. How each of the 6 registries collapses (and how validation still holds)

### 3.1 `ParameterTargetID.coreAndEffect` → derived
```swift
extension ParameterTargetID {
    static var coreAndEffect: [String] { ParameterCatalog.routedDescriptors.map(\.id) }
}
```
**[ADVERSARY-MAJOR fold-in #1]** It derives from `routedDescriptors`, NOT `allDescriptors`.
`ControlCatalog` holds ~10 *long-tail* specs (`sphericalInversionRadius`, `colorIterations`,
`rotationSnapWindowDegrees`, `resolutionScale`, color-grading — `ControlSpec.swift:179-234`)
that deliberately have **no routed node** and are excluded from `allSpecs` (`:168-176`).
`routedDescriptors` == today's 11. Any long-tail descriptor added later goes into
`allDescriptors` only, so it can never trip the routing preconditions.

### 3.2 `ParameterOperationDispatcher.coreDescriptors` → deleted (static path only)
The 11-entry literal (`ParameterOperationSystem.swift:146-202`) is removed.
`routableDescriptorTargetIDs` and `applyCore` read from the catalog:
```swift
static var routableDescriptorTargetIDs: Set<String> {
    Set(ParameterCatalog.routedDescriptors.map(\.id))
}
private func applyCore(_ op: ParameterOperation, settings: RenderSettings?, layer: ParameterLayer) {
    guard let settings, let d = ParameterCatalog.byID[op.targetID] else { return }
    let bind = d.settings                       // SettingsBinding — @Sendable, off-main safe
    let base = bind.read(settings)
    // ...exact same coreStacks logic as ParameterOperationSystem.swift:372-384,
    //    using d.spec.range + d.spec.motionStrategy...
    bind.write(settings, d.clamp(resolved))
}
```
**[ADVERSARY-MAJOR fold-in #2 — formula stays dynamic]** This is the STATIC path only.
The formula branch (`apply(_:settings:)`, `ParameterOperationSystem.swift:321-362`) is
**untouched**: it still parses the id, keys `formulaStacks` by the dynamic id, and resolves
range/motion from the LIVE per-fractal node via
`ParameterNodeRegistry.shared.node(for:formulaIndex:)` (`:326-334`). `ParameterCatalog.byID`
is intentionally empty for formula ids (per-fractal + `.custom`-dynamic), so the dispatcher's
top-level branch is: `if parseFormulaID(id) != nil { dynamic formula path } else { catalog path }`.
`coreValue(for:settings:)` (`:118-120`) and `clearMusicLayers` (`:462-466`) likewise switch
from `coreDescriptors[id]` to `ParameterCatalog.settingsBinding(for: id)`.

### 3.3 `buildCoreAndEffectNodes` inline metadata → `FloatParameterNode(descriptor:)`
```swift
extension FloatParameterNode {
    convenience init(descriptor d: ParameterDescriptor, group: ParameterGroup?) {
        self.init(spec: d.spec, group: group,
                  isGestureMappable: d.gesture?.isMappable ?? false,
                  readValue: d.ui.read, writeValue: d.ui.write)   // @MainActor pair
    }
}
// buildCoreAndEffectNodes -> ParameterCatalog.routedDescriptors.reduce(into:[:]) { ... }
```
Group assignment (core/effect/space) is the only local bit; it can be carried as a small
`group` field on the descriptor or derived from the `route`.

### 3.4 The three `gestureBindable*` methods → one filtered projection
**[GRAFT from "Descriptor-owns-everything" + judges' best-ideas]** `gestureBindableParameters`,
`gestureBindableTriplets`, `gestureBindableCoreParameters` (`ParameterNodeSystem.swift:520-612`)
collapse to one capability filter over nodes, with triplet grouping keyed off
`gesture.tripletGroupKey` instead of re-parsing `.x/.y/.z`:
```swift
func gestureBindable(for type: FractalModelType) -> [GestureBindableParameter] {
    (routedNodes + formulaBatch(for: type).floatNodes)
        .filter { $0.isGestureMappable && descriptor(for: $0)?.capability.isAvailable(type) ?? true }
        .map { GestureBindableParameter(fractalType: type, parameterNodeID: $0.id, ...) }
}
```
The hardcoded `[sphereProjectionBlend.id, sphereProjectionRadius.id]` list disappears (it
becomes "routed nodes that are gesture-mappable"). The persisted `GestureBindableParameter`/
`GestureBindableTriplet` payloads are **unchanged** (still key by `parameterNodeID`).

### 3.5 `MusicReactiveTarget` switch bodies → descriptor projections
```swift
var category: MusicReactiveTargetCategory {
    if let id = parameterTargetID, let m = ParameterCatalog.byID[id]?.music { return m.category }
    switch self.migrated { /* ONLY formula-slot + foldingLimit/sphereRadius arms remain */ }
}
// same shape for defaultSource / defaultResponseCurve / hasFlashingRisk
```
**[ADVERSARY-NONE fold-in — persistence]** The delegation is keyed on the **raw `self`'s**
`parameterTargetID` guarded by spec-present, so legacy `foldingLimit`/`sphereRadius` (whose
`parameterTargetID` is a Mandelbox formula id absent from `byID`, `MusicReactiveTypes.swift:445-446`)
correctly fall through to their legacy switch arm — NOT routed through `formulaParam1`'s facet.
`hasFlashingRisk` keeps switching on `self.migrated` exactly as today (`:401`).
`availableCases`/`availableCases(for:)` become `MusicReactiveTarget.allCases.filter { ... }`
gated by `capability.isAvailable(type)` for routed cases, formula-slot count for formula cases.

### 3.6 `RenderSettings` clamp / `audioModulate<Name>` → reads descriptor range
**[GRAFT — retire the 6th registry, scheduled as a LATE slice]** The `audioModulate<Name>`
setters hardcode their clamp (a 4th, validator-invisible range copy). A generic
`audioModulate(targetID:value:)` that clamps via `ParameterCatalog.byID[id].clamp` closes it,
and `validateStartupRouting` gains an assert that each setter literal == `spec.range`.
This touches the hot path, so it is the **final** slice, separately verified — not bundled.

### 3.7 validateStartupRouting still holds (and is NOT made blind)
**[ADVERSARY-MAJOR fold-in #3 — the critical one]** When `coreAndEffect`/descriptors/node ids
all derive from one list, preconditions #1/#3 (`ParameterTargetID.swift:64-71`) become
tautologies. To keep the tripwire **real**, anchor it on the one source that is NOT derived
from the node list — `ControlCatalog.allSpecs` (`routedDescriptors` is built from it) — with
**bidirectional set equality**:
```swift
let specIDs = Set(ControlCatalog.allSpecs.map(\.id))
let nodeIDs = Set(registry.coreNodes.keys).union(registry.effectNodes.keys)
precondition(specIDs == nodeIDs,                       // catches spec-without-node AND node-without-spec
    "Routed spec/node set mismatch.")
for spec in ControlCatalog.allSpecs {                  // range-drift guard (#4) STAYS
    let node = registry.coreNodes[spec.id] ?? registry.effectNodes[spec.id]
    precondition(node?.range == spec.range, "Range drift on \(spec.id).")
    if let t = MusicReactiveTarget.availableCases.first(where: { $0.parameterTargetID == spec.id }) {
        precondition(t.allowedRange == spec.range, "Music range drift on \(spec.id).")  // #5 STAYS
    }
}
```
The bidirectional equality restores the cross-check that derivation would otherwise lose, so a
node authored without a spec (or a routed descriptor without a node) still trips at launch.

**[ADVERSARY-MAJOR fold-in — formula range guard goes to BUILD TIME, not startup]** Do NOT add
a formula range assert to `validateStartupRouting` (it runs once at startup against
possibly-unbuilt `.custom` batches). Instead assert `node.range == generatedDescriptor.range`
**inside `buildFormulaBatch` under `formulaBatchLock`** (`ParameterNodeSystem.swift:623-693`),
where node and descriptor are guaranteed to coexist. This finally brings formula ranges under a
tripwire (the audit-flagged gap) without a startup race.

---

## 4. Persistence: every rawValue stays frozen

- **`MusicReactiveTarget`** stays `String, CaseIterable, Codable` with ALL cases incl. legacy
  `foldingLimit`/`sphereRadius` (`MusicReactiveTypes.swift:198-199`) and the `.migrated`
  mapping (`:248-254`). Only switch *bodies* project from descriptors; the case set + rawValues
  + decode→migrate path are byte-stable. **[ADVERSARY-NONE]** A `MusicReactiveMapping.init(from:)`
  fallback (`?? target.defaultResponseCurve`) re-derives the curve for old `.threshmp` files, so
  a transcription slip in a `MusicFacet` literal would silently regress a stored preset — the
  golden test in §6 is therefore mandatory before any switch arm is deleted.
- **`ParameterTargetID`** string constants (`core.fractalScale`, `space.sphereProjectionBlend`)
  are reused verbatim as `spec.id`; the formula grammar `formula.<rawValue>.<index>.<name>`
  (`:41`) and `parseFormulaID` (`:44-54`) are untouched (formula descriptors reuse them).
- **`FractalModelType`** dual encoding (codableString vs Int32 rawValue) untouched.
- **`FractalPreset`/.threshscene/.threshmp/.threshanim`, `FractalDefaultsStore`
  ('customFractalDefaults.v1'), `FormulaParams` memcpy layout, `ModuleKey` rawValues,
  `GestureBindableParameter/Triplet` Codable** — all untouched. The descriptor is never encoded.

---

## 5. @MainActor / off-main / Sendable story

The descriptor is a `Sendable` value type holding two **differently-isolated** closure pairs.
Storing a `@MainActor @Sendable` closure beside a non-isolated `@Sendable` closure in a
`Sendable` struct is legal; only *calling* the @MainActor one cross-actor is illegal — and that
is a **compile error**, not a silent race.

- `UIBinding.read/write` are `@MainActor @Sendable (UISettingsCache) -> ...` — invoked ONLY from
  the @MainActor cache path (`dispatch(_:cache:)`, `ParameterOperationSystem.swift:267`), via the
  node's cached closures.
- `SettingsBinding.read/write` are `@Sendable (RenderSettings) -> ...` — invoked ONLY from the
  off-main path (`dispatch(_:settings:)`, `:310` / `applyCore`, `:367`), which writes solely
  through lock-protected `RenderSettings` (`@unchecked Sendable`, `os_unfair_lock`).

**[ADVERSARY-MINOR fold-in — make the footgun impossible]** `applyCore` is reached from BOTH
paths; once it looks up the full descriptor, the @MainActor `ui.write` is lexically in scope on
the off-main path (can't be *called*, but it's there). Eliminate it: the off-main path looks up
**`ParameterCatalog.settingsBinding(for: id)`** — a narrowed projection returning ONLY the
`@Sendable` pair — never the full `ParameterDescriptor`. The full descriptor (with the ui pair)
is reachable only through `FloatParameterNode(descriptor:)` on the @MainActor build path.

**[ADVERSARY-MINOR fold-in — annotation upgrade is explicit]** Moving the 11 `coreDescriptors`
closures onto `SettingsBinding` upgrades them from `(RenderSettings)->Float` (non-`@Sendable`,
`ParameterOperationSystem.swift:129-130`) to `@Sendable`. This compiles because each captures
only its `RenderSettings` arg (itself `@unchecked Sendable`) — but it IS a change, noted so a
reviewer expects it. `FloatParameterNode` stays `@unchecked Sendable` (mutable state still the
single `Mutex<ParameterLayerStack>`; the descriptor it was built from is not retained as mutable
state). `ParameterCatalog` is a `static let` of immutable value types — trivially Sendable.

---

## 6. Dynamic per-fractal formula nodes

**[GRAFT — formula descriptors generated, never authored]** Formula nodes fit the same model
via a *generated* descriptor, unifying construction with core/effect AND bringing formula ranges
under a tripwire for the first time:
```swift
extension ParameterDescriptor {
    static func makeFormula(type: FractalModelType, param: FormulaParamDescriptor) -> ParameterDescriptor {
        // id = ParameterTargetID.formula(type, param.index, param.name)   (grammar unchanged)
        // spec = ControlSpec(id:, name: displayLabel(param.name), icon: icon(param.name),
        //                    range: param.min...param.max, default: param.default,
        //                    motion: formulaMotionStrategy(type, param.index))
        // gesture = GestureFacet(isMappable: true, tripletGroupKey: xyzPrefix(param.name))
        // capability = .requires { FormulaCatalog.shared.descriptor(for:$0) has this index }
        // music = nil  (formula music routes via legacy formulaParam0..15 enum cases)
        // ui = the cache.formulaParams / setManualFormulaParamOverride pair (ParameterNodeSystem.swift:671-680)
        // settings = the FormulaCatalog.get/setParam-by-index pair
    }
}
```
- **[ADVERSARY-MAJOR fold-in]** `buildFormulaBatch` (`ParameterNodeSystem.swift:623-693`) keeps
  its **exact lifecycle**: built per `FractalModelType`, `.custom` rebuilt under
  `formulaBatchLock` on descriptor-id change (`:499-514`), `clearFormulaStacks` on type switch
  (`:489-498`). `makeFormula` is generated *inside* `buildFormulaBatch`, never cached as authored
  data — so dynamic rebuild + stale-stack eviction are preserved.
- **[ADVERSARY-MAJOR fold-in]** The DISPATCHER's formula branch resolves range/motion from the
  LIVE node (`node(for:formulaIndex:)`, `:326-334`), NEVER from static `ParameterCatalog.byID`
  (which is empty for formula ids). The catalog unifies *construction* of nodes; the off-main
  formula apply path stays node-resolved.
- The range guard is asserted at build time (§3.7), not startup.

---

## 7. Incremental migration plan (ordered, each buildable on Mac + visionOS)

Build: `xcodebuild ... CODE_SIGNING_ALLOWED=NO` for `ThresholdMac` (all Swift+Metal) and
`-destination 'generic/platform=visionOS'`. `validateStartupRouting` is the runtime tripwire;
every slice must launch green. Each slice is independently revertible.

| Slice | Title | Collapses | Risk | Breaking | On-device check |
|---|---|---|---|---|---|
| 1 | Author `ParameterCatalog` ALONGSIDE live tables; DERIVE the sets; add golden equality test | (none deleted; derivation proven) | low | no | App launches (validator green); sphere blend slider/gesture/music still work |
| 2 | Re-point `coreAndEffect` + `routableDescriptorTargetIDs` to `routedDescriptors`; tighten validator to bidirectional `allSpecs`==nodeIDs equality; delete preconditions #1/#3 | ParameterTargetID.coreAndEffect | low | no | Launch green; a deliberately-mismatched node (test) trips the new equality assert |
| 3 | Delete `coreDescriptors`; `applyCore` + `coreValue` + `clearMusicLayers` read `ParameterCatalog.settingsBinding(for:)` | dispatcher coreDescriptors | medium | no | Gesture + audio on glow/bloom/fractalScale unchanged; ghost markers track |
| 4 | `buildCoreAndEffectNodes` → `FloatParameterNode(descriptor:)` | node inline metadata | low | no | All 11 sliders move; ranges unchanged (validator #4 green) |
| 5 | `MusicReactiveTarget` 4 switch bodies → descriptor projections (keep enum/rawValues/legacy arms); golden old==new test gates deletion | music defaults switches | low | no | Music add-menu defaults (source/curve/category/flashing) identical per case |
| 6 | Collapse 3 `gestureBindable*` → one capability filter; add `tripletGroupKey` | gesture assemblers | low | no | Finger-binding menu lists same scalars + xyz triplets |
| 7 | Generate formula descriptors via `makeFormula`; assert range under `formulaBatchLock` | formula construction unified + ranged | medium | no | Switch through all 12 fractals + `.custom`; formula sliders/gestures unchanged |
| 8 | Activate `route`: one tab section renders data-driven via `routedDescriptors.filter{route.tab==…}` | (pilots dead `Module.route`) | medium | no | Shape tab visual order pixel-matches hand-placed layout |
| 9 (deferred) | Generic `audioModulate(targetID:)` clamping via `descriptor.clamp`; assert setter literal == spec.range | RenderSettings clamp drift (6th registry) | high | no | Audio-driven blend/radius clamp identically at extremes |

---

## 8. Unresolved / known-remaining after the safe set

- **Two-stack split is NOT merged** (slices 1–8). Node `_layerStack` vs dispatcher
  `coreStacks`/`formulaStacks` remain separate, bridged by `recenterMusicBase`/
  `requestMusicRecenter` (`ParameterOperationSystem.swift:419-433`, `:275`, `:318`). The
  descriptor unifies *authoring*; it never touches stack storage or recenter routing
  (`recenterMusicBase` stays keyed on `parseFormulaID != nil`, `:420`). A naive merge
  reintroduces the slider-stomped-by-music bug — out of scope.
  **[ADVERSARY-MINOR clarification]** For the 11 routed nodes the `_layerStack` is effectively
  *inert* (core/effect route through `coreStacks` via `applyCore`); the genuine two-stack split
  is a **formula-only** phenomenon. So co-locating bindings on those 11 descriptors is even safer
  than feared.
- **RenderSettings clamp drift** (6th registry) stays until slice 9.
- **Long-tail specs** (`ControlSpec.swift:179-234`) remain unrouted; promoting them to full nodes
  is future work (they go into `allDescriptors`, never `routedDescriptors`).


---

## Incremental migration plan (strangler-fig, each slice buildable + non-breaking)

### Slice 1 — Author ParameterCatalog alongside live tables; derive sets; add golden equality net
- **Risk:** low  •  **Breaking:** False  •  **Builds alone:** True
- **Files:** Threshold/Parameters/ControlSpec.swift; Threshold/Parameters/ParameterTargetID.swift
- **On-device check:** App launches with all validateStartupRouting preconditions + new equality asserts green; sphere Projection Blend slider/gesture/music behave identically.

### Slice 2 — Derive coreAndEffect + routableDescriptorTargetIDs from routedDescriptors; tighten validator to bidirectional allSpecs==nodeIDs; delete preconditions #1/#3
- **Risk:** low  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** ParameterTargetID.coreAndEffect; validateStartupRouting #1/#3 (now anchored on allSpecs equality, NOT tautological)
- **Files:** Threshold/Parameters/ParameterTargetID.swift; Threshold/Parameters/ParameterOperationSystem.swift
- **On-device check:** Launch green; inject a node without a spec in a debug build and confirm the new bidirectional equality precondition trips.

### Slice 3 — Delete dispatcher coreDescriptors; applyCore/coreValue/clearMusicLayers read ParameterCatalog.settingsBinding(for:)
- **Risk:** medium  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** ParameterOperationDispatcher.coreDescriptors (static path)
- **Files:** Threshold/Parameters/ParameterOperationSystem.swift
- **On-device check:** Gesture + audio modulation on glow/bloom/fractalScale/sphere blend unchanged; DerivedValueGhost markers still track; clearMusicLayers on audio-stop zeroes correctly.

### Slice 4 — buildCoreAndEffectNodes builds via FloatParameterNode(descriptor:)
- **Risk:** low  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** node inline metadata in buildCoreAndEffectNodes
- **Files:** Threshold/Parameters/ParameterNodeSystem.swift
- **On-device check:** All 11 core/effect/space sliders move with identical ranges; validateStartupRouting range-drift (#4) green.

### Slice 5 — MusicReactiveTarget category/defaultSource/defaultResponseCurve/hasFlashingRisk project from descriptor; keep enum+rawValues+legacy arms; gate deletion on golden test
- **Risk:** low  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** MusicReactiveTarget 4 metadata switches (canonical arms)
- **Files:** Threshold/Audio/MusicReactiveTypes.swift
- **On-device check:** For every MusicReactiveTarget case the add-menu default source/curve/category/flashing is identical to before; an old .threshmp with a sphere-blend mapping loads with the same curve.

### Slice 6 — Collapse three gestureBindable* methods into one capability filter; add tripletGroupKey
- **Risk:** low  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** gestureBindableParameters / gestureBindableTriplets / gestureBindableCoreParameters; hardcoded [blend.id,radius.id] list
- **Files:** Threshold/Parameters/ParameterNodeSystem.swift; Threshold/Gestures/FingerGestureAction.swift
- **On-device check:** Finger-binding menu lists the same scalars + the same xyz triplets per fractal; binding persistence round-trips (parameterNodeID identity unchanged).

### Slice 7 — Generate formula nodes via ParameterDescriptor.makeFormula; assert node.range==descriptor.range under formulaBatchLock
- **Risk:** medium  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** formula node construction unified with core/effect; formula ranges brought under a build-time tripwire
- **Files:** Threshold/Parameters/ParameterNodeSystem.swift
- **On-device check:** Switch through all 12 fractal types + .custom; formula sliders, gestures, triplets, and audio mappings behave identically; no precondition trips on type switch or .custom rebuild.

### Slice 8 — Activate route: render one tab section data-driven from routedDescriptors filtered by route.tab
- **Risk:** medium  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** pilots the currently-dead Module.route / modules(forTab:) mechanism for parameters
- **Files:** Threshold/App/ContentView+FractalTab.swift; Threshold/App/ModuleSectionView.swift; Threshold/Parameters/ControlSpec.swift
- **On-device check:** Shape tab visual order + section grouping pixel-matches the prior hand-placed layout on Mac and visionOS.

### Slice 9 — Generic audioModulate(targetID:value:) clamping via descriptor.clamp; assert setter literal==spec.range (deferred, hot-path)
- **Risk:** high  •  **Breaking:** False  •  **Builds alone:** True
- **Collapses:** RenderSettings audioModulate clamp drift (the 6th registry)
- **Files:** Threshold/Parameters/RenderSettings.swift; Threshold/Parameters/ParameterTargetID.swift
- **On-device check:** Audio-driven sphere blend/radius and glow/bloom clamp identically at min/max extremes; per-frame audio path shows no regression at <45fps on Vision Pro.


## Slice 1 — implementation-ready spec

SLICE 1 — additive, non-breaking, makes existing registries DERIVE from one authored list without deleting anything.

NEW TYPES (add to Threshold/Parameters/ControlSpec.swift, or a sibling ParameterCatalog.swift):
- `struct MusicFacet: Sendable { let category: MusicReactiveTargetCategory; let defaultSource: MusicReactiveSource; let defaultResponseCurve: ResponseCurve; let hasFlashingRisk: Bool }`
- `struct GestureFacet: Sendable { let isMappable: Bool; let tripletGroupKey: String? }`
- `enum ParameterCapability: Sendable { case universal; case requires(@Sendable (FractalModelType) -> Bool); func isAvailable(_ t: FractalModelType) -> Bool { switch self { case .universal: true; case .requires(let p): p(t) } } }`
- `struct UIBinding: Sendable { let read: @MainActor @Sendable (UISettingsCache) -> Float; let write: @MainActor @Sendable (UISettingsCache, Float) -> Void; let persists: Bool }`
- `struct SettingsBinding: Sendable { let read: @Sendable (RenderSettings) -> Float; let write: @Sendable (RenderSettings, Float) -> Void }`
- `struct ParameterDescriptor: Sendable, Identifiable { let spec: ControlSpec; let route: ParameterRoute?; let capability: ParameterCapability; let gesture: GestureFacet?; let music: MusicFacet?; let ui: UIBinding; let settings: SettingsBinding; var id: String { spec.id }; func clamp(_ v: Float) -> Float { spec.clamp(v) } }` (ParameterRoute may reuse Module.swift's ModuleRoute or be a thin {tab,section,order}; in slice 1 route can be nil throughout.)

AUTHOR ParameterCatalog with exactly the 11 routed descriptors, re-using ControlCatalog specs for metadata and COPYING the existing closure pairs verbatim from their two current sites:
- `ui.read`/`ui.write` copied from buildCoreAndEffectNodes (ParameterNodeSystem.swift:397-494) — e.g. sphereProjectionBlend: read {$0.display.sphereProjectionBlend}, write {c,v in c.display.sphereProjectionBlend=v; c.commitSphereProjection()}, persists:true.
- `settings.read`/`settings.write` copied from coreDescriptors (ParameterOperationSystem.swift:146-202) — e.g. read {$0.sphereProjectionBlend}, write {s,v in s.audioModulateSphereProjectionBlend(v)}.
- `music` copied from the MusicReactiveTypes switches (category :276, defaultSource :342, defaultResponseCurve :377, hasFlashingRisk :400) — e.g. sphereProjectionBlend: category .geometry, source .composite, curve .drift, flashing false.
- `capability`: .universal for all 11 (sphere blend/radius are cross-fractal universal today).
Provide: `routedDescriptors: [ParameterDescriptor]` (declaration order matching ControlCatalog.allSpecs / ParameterTargetID.coreAndEffect); `byID = Dictionary(uniqueKeysWithValues: routedDescriptors.map{($0.id,$0)})`; `allDescriptors = routedDescriptors` (long-tail added later); `static func settingsBinding(for id: String) -> SettingsBinding? { byID[id]?.settings }`.

DO NOT in slice 1: delete coreDescriptors, change buildCoreAndEffectNodes, re-point coreAndEffect, change MusicReactiveTarget, or touch RenderSettings/UISettingsCache/dispatcher apply paths. The live tables stay authoritative; the catalog merely COEXISTS.

WHAT BECOMES DERIVED (proven, not yet consumed): add a DEBUG block to ParameterRoutingValidation.validateStartupRouting() (ParameterTargetID.swift:58) AFTER the existing preconditions:
  let catalogIDs = Set(ParameterCatalog.routedDescriptors.map(\.id))
  precondition(catalogIDs == Set(ParameterTargetID.coreAndEffect), "Catalog/coreAndEffect id mismatch")
  precondition(catalogIDs == Set(registry.coreNodes.keys).union(registry.effectNodes.keys), "Catalog/node id mismatch")
  // GOLDEN equality (the migration safety net): for each routed id, assert the catalog descriptor's
  // range == ControlCatalog.spec(id).range and motionStrategy == spec.motionStrategy (these drive
  // coreStacks clamp/smoothing later); and for each MusicReactiveTarget whose parameterTargetID is in
  // catalogIDs, assert music facet category/defaultSource/defaultResponseCurve/hasFlashingRisk == the
  // enum's current switch result (proves §3.5 will be byte-stable before any switch arm is deleted).
This keeps the EXISTING validateStartupRouting preconditions (#1-#5) fully intact and ADDS the equality net — nothing is made tautological yet (that is slice 2).

HOW validateStartupRouting STILL PASSES: unchanged — slice 1 adds asserts, removes none. The new asserts pass by construction because the catalog is hand-authored to equal the live sources, and the golden test mechanically compares copied values to their origin.

PROOF IT BUILDS + DOES NOT BREAK PERSISTENCE: (1) Compiles on Mac (all Swift) + visionOS generic destination, CODE_SIGNING_ALLOWED=NO — the new types are value types with closures that capture only their UISettingsCache/RenderSettings arg; storing @MainActor @Sendable beside @Sendable in a Sendable struct is legal because slice 1 never CALLS them (compile error if mis-called, so the seam is compiler-guarded). (2) Zero persisted-format change: ParameterDescriptor is non-Codable and never serialized; no enum case, rawValue, CodingKey, or string id is added or renamed; MusicReactiveTarget, ParameterTargetID constants, FractalPreset/.threshmp/.threshscene/FractalDefaultsStore are untouched. (3) Hot path untouched: dispatcher apply(_:cache:)/apply(_:settings:)/applyCore are byte-for-byte unchanged, so the two-stack split and recenter machinery are unaffected.

FILES TOUCHED: Threshold/Parameters/ControlSpec.swift (or new ParameterCatalog.swift) — add types + catalog (~150 lines, additive). Threshold/Parameters/ParameterTargetID.swift — add the DEBUG equality block to validateStartupRouting (~15 lines). No other file changes.

ON-DEVICE CHECK: launch ThresholdMac and the visionOS sim build; app must start without tripping any precondition (proves catalog == live sources). Move the sphere Projection Blend slider, finger-drag it, and enable a music mapping on it — all three must behave exactly as before (no behavior change is intended).


## Deliberately NOT done (documented limits)

- Two-stack split (node _layerStack vs dispatcher coreStacks/formulaStacks) is deliberately NOT merged in slices 1-8; recenterMusicBase/requestMusicRecenter bridging must stay keyed on parseFormulaID. A future naive merge reintroduces the slider-stomped-by-frozen-music-base bug (memory music-param-two-stack-split). For the 11 routed nodes the _layerStack is effectively inert (they route through coreStacks), so the genuine split is formula-only — but this must be documented at the binding site so a later dev does not assume the node owns one unified stack.
- RenderSettings audioModulate<Name> clamp literals remain a validator-invisible 4th range copy until slice 9 (hot-path, deferred). Until then 'lockstep fully collapsed' is overstated for the clamp dimension; document as known-remaining.
- Slice 5 golden test is load-bearing for persistence: MusicReactiveMapping.init(from:) re-derives responseCurve from defaultResponseCurve for old .threshmp files, so a mis-transcribed MusicFacet literal silently regresses stored presets. The old-switch==facet-derived assert must be green BEFORE any switch arm is deleted.
- Slice 8 route-driven rendering must reproduce the current hand-placed visual order exactly (ModuleRoute order field), or the Shape/Effects tabs silently reshuffle. Needs a visual snapshot diff on both Mac and visionOS, not just a launch check.
- ParameterDescriptor is intentionally NON-Equatable (holds closures); ControlSpec stays Equatable for the validator/tests. Keep the Equatable metadata (ControlSpec) and the non-Equatable bindings as separate fields so existing range-equality asserts (node.range==spec.range) keep compiling.

## On-device verification required

- validateStartupRouting passes at launch on ThresholdMac AND visionOS generic build after EACH slice (it is a runtime DEBUG precondition, not compile-time) — this is the primary cross-slice gate.
- Slice 3: gesture + audio modulation on glow/bloom/fractalScale/sphereProjectionBlend produce identical motion to pre-slice, and DerivedValueGhost markers track resolved values, since applyCore now sources read/write closures from the catalog instead of coreDescriptors.
- Slice 5: enumerate every MusicReactiveTarget case in the add-menu and confirm default source/curve/category/flashing-risk are unchanged; load an old .threshmp containing a sphereProjectionBlend mapping and confirm the curve is unchanged.
- Slice 7: cycle through all 12 FractalModelType cases plus .custom (rebuild path under formulaBatchLock) and confirm formula sliders/gestures/triplets/audio mappings behave identically and no precondition trips on type switch.
- Slice 8: pixel/visual-order comparison of the route-driven tab section vs the prior hand-placed ModuleSectionView layout on both Mac and Vision Pro.
- Slice 9: per-frame audio path performance on Vision Pro (GPU-bound <45fps regime from memory threshold-perf-model) shows no regression, and audio-driven clamp at parameter extremes matches the prior hardcoded clamp bounds exactly.
