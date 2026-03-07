# Gesture UI Revamp — Per-Hand Binding Architecture

## Overview

Replace the current 4-finger binding model (index/middle/ring/pinky → one action each) with a **per-hand × per-finger** model: **Left Hand**, **Right Hand**, and **Both Hands**, each with **index, middle, ring** (pinky dropped). This yields **9 binding slots** total.

Each hand mode implies a different gesture mechanic:
- **Left / Right** (single-hand): Pinch-drag with one hand — 3D position delta drives triplet params, translation, or 1D scalar (vertical component)
- **Both** (two-hand): Both hands pinch same finger → pull-apart distance maps to scalar param (existing two-hand gesture logic)

---

## Current State (What Exists)

| Layer | Current | Files |
|---|---|---|
| **Binding slots** | 4 per-digit: index/middle/ring/pinky | `RenderSettings.swift` |
| **Binding type** | `GestureActionBinding` (.core, .parameter, .parameterTriplet) | `FingerGestureAction.swift` |
| **Gesture dispatch** | Loop digits 1-4, all use two-hand logic except triplets (right-hand pinch-drag) | `GestureController.swift` |
| **Translation** | Hardcoded `processRightIndexDrag()` — always right-hand index | `GestureController.swift` |
| **UI** | Flat list of 4 finger pickers | `GestureSettingsView.swift`, `ContentView.swift` |
| **Param editor** | "Assign to finger" menu shows `FingerPair` (index/middle/ring/pinky) | `FormulaParamsEditor.swift` |
| **Cache** | Mirrors 4 binding fields | `UISettingsCache.swift` |

---

## New Architecture

### 1. Data Model Changes

#### A. `GestureHandMode` enum (new)
```swift
enum GestureHandMode: String, CaseIterable, Codable {
    case left   // single-hand pinch-drag
    case right  // single-hand pinch-drag
    case both   // two-hand pull-apart
}
```

#### B. `GestureSlot` (replaces `FingerPair`)
```swift
struct GestureSlot: Hashable, Codable {
    let hand: GestureHandMode
    let finger: FingerDigit  // index=1, middle=2, ring=3
}

enum FingerDigit: Int, CaseIterable, Codable {
    case index = 1, middle = 2, ring = 3
}
```

#### C. `FingerGestureAction` — add `.translate`
- New case `.translate` for position XYZ pinch-drag
- Valid only for left/right hand modes (single-hand gesture)
- Replaces the hardcoded `processRightIndexDrag()`

#### D. Binding availability by hand mode
| Binding Type | Left | Right | Both |
|---|---|---|---|
| `.core(.translate)` | ✅ | ✅ | ❌ |
| `.core(.grab)` | ❌ | ❌ | ✅ |
| `.core(.fractalScale)` | ❌ | ❌ | ✅ |
| `.core(.minDistance/.foldingLimit/.sphereRadius)` | ❌ | ❌ | ✅ |
| `.parameter(scalar)` | ✅ (1D drag) | ✅ (1D drag) | ✅ (two-hand) |
| `.parameterTriplet(xyz)` | ✅ | ✅ | ❌ |
| `.core(.none)` | ✅ | ✅ | ✅ |

`GestureActionBinding.availableBindings(for:handMode:)` gets a new `handMode` parameter to filter.

### 2. Storage (RenderSettings.swift)

Replace 4 fields with 9:
```
_leftIndexBinding    _leftMiddleBinding    _leftRingBinding
_rightIndexBinding   _rightMiddleBinding   _rightRingBinding
_bothIndexBinding    _bothMiddleBinding    _bothRingBinding
```

**Persistence keys**: `"leftIndexBinding"`, `"rightMiddleBinding"`, etc.

**Defaults**:
| Slot | Default |
|---|---|
| Right Index | `.core(.translate)` |
| Right Middle | `.core(.none)` |
| Right Ring | `.core(.none)` |
| Left Index | `.core(.none)` |
| Left Middle | `.core(.none)` |
| Left Ring | `.core(.none)` |
| Both Index | `.core(.grab)` |
| Both Middle | `.core(.minDistance)` |
| Both Ring | `.core(.fractalScale)` |

**Migration**: On first load, if old keys exist (`indexFingerBinding` etc.), migrate:
- Old index → `bothIndexBinding`
- Old middle → `bothMiddleBinding`  
- Old ring → `bothRingBinding`
- Old pinky → dropped (was `.core(.sphereRadius)`, which moves to `.core(.none)` or stays unbound)
- Set `rightIndexBinding` = `.core(.translate)` (preserves existing behavior)

**Lookup methods** updated:
```swift
func binding(for slot: GestureSlot) -> GestureActionBinding
func slot(for binding: GestureActionBinding) -> GestureSlot?
```

**Sanitizer** updated to iterate all 9 slots on fractal type change.

### 3. Cache (UISettingsCache.swift)

Mirror all 9 slots. Update `setBinding(_:for:)` and `slot(for:)` to use `GestureSlot`.

### 4. Gesture Controller (GestureController.swift)

#### Remove `processRightIndexDrag()`
Translation becomes a binding like any other — when a left/right slot has `.core(.translate)`, the single-hand drag logic runs for that hand+finger.

#### New processing structure:
```swift
private func processGestures() {
    // 1. Check suppression
    
    // 2. Process BOTH-hand bindings (digits 1-3)
    for digit in 1...3 {
        let binding = settings.binding(for: GestureSlot(hand: .both, finger: FingerDigit(rawValue: digit)!))
        // → processTwoHandGesture / processTwoPointGrab / processCoreScaleGesture
    }
    
    // 3. Process LEFT-hand bindings (digits 1-3)
    for digit in 1...3 {
        let binding = settings.binding(for: GestureSlot(hand: .left, finger: FingerDigit(rawValue: digit)!))
        // → processSingleHandDrag(hand: .left, digit:, binding:)
    }
    
    // 4. Process RIGHT-hand bindings (digits 1-3)
    for digit in 1...3 {
        let binding = settings.binding(for: GestureSlot(hand: .right, finger: FingerDigit(rawValue: digit)!))
        // → processSingleHandDrag(hand: .right, digit:, binding:)
    }
}
```

#### `processSingleHandDrag(hand:digit:binding:)` (unified)
Replaces both `processRightIndexDrag()` and `processTripletDrag()`:
- For `.core(.translate)`: position XYZ drag (current right-index logic)
- For `.parameterTriplet`: XYZ triplet drag (current triplet logic)
- For `.parameter`: 1D scalar drag using vertical component
- For `.core(.none)`: skip

**State tracking** — replace separate `rightIndexDrag*` and `tripletDrag*` vars with a per-slot state dict:
```swift
private var singleHandDragState: [GestureSlot: SingleHandDragState] = [:]

struct SingleHandDragState {
    var isActive: Bool = false
    var startPos: SIMD3<Float> = .zero
    var prevPos: SIMD3<Float> = .zero
    var startValues: SIMD3<Float> = .zero  // for triplets
    var startValue: Float = 0              // for scalars
    var accumulatedPosition: SIMD3<Float> = .zero  // for translate
}
```

**Two-hand state** — `fingerGestureState` changes from `[Int: TwoHandGestureState]` keyed by digit 1-4 to keyed by digit 1-3 (same struct, just 3 entries).

**Conflict resolution**: If a "both" gesture is active for a given digit, the corresponding left/right single-hand gesture for that digit is suppressed (both hands are pinching).

### 5. Settings UI (GestureSettingsView.swift)

New layout:
```
┌─ Gesture Controls ─────────────────────────────┐
│ [status] [hand icons]                           │
│ ☑ Enable Hand Gesture Controls                  │
│                                                 │
│ ── Core Behavior ──                             │
│ ☑ Relative Gestures                             │
│ ☑ Extended Range                                │
│ [Global Sensitivity ─────●──]                   │
│ [Translation Sensitivity ──●─]                  │
│                                                 │
│ ── Hand Assignments ──                          │
│                                                 │
│ 🫲 Left Hand                                    │
│   Index   [picker ▼]                            │
│   Middle  [picker ▼]                            │
│   Ring    [picker ▼]                            │
│                                                 │
│ 🫱 Right Hand                                   │
│   Index   [picker ▼]  (default: Translate)      │
│   Middle  [picker ▼]                            │
│   Ring    [picker ▼]                            │
│                                                 │
│ 🙌 Both Hands                                   │
│   Index   [picker ▼]  (default: Grab)           │
│   Middle  [picker ▼]  (default: Min Distance)   │
│   Ring    [picker ▼]  (default: Fractal Scale)  │
│                                                 │
│ ── Menu Toggle ──                               │
│ ── Gesture Lab ──                               │
└─────────────────────────────────────────────────┘
```

Each picker shows only the bindings valid for that hand mode via `availableBindings(for:handMode:)`.

Triplet bindings appear as a single row (e.g., "Kleinian Mins (XYZ)") — no sub-component breakdown.

### 6. ContentView.swift

Replace the 4 `fingerActionPicker` calls in the settings tab with a reference to the new hand-grouped pickers (either inline or via `GestureSettingsView`). Remove the old `fingerActionPicker` helper if it's fully replaced.

### 7. FormulaParamsEditor.swift

Update the "Assign to gesture" menu:
- Instead of showing `FingerPair` options, show `GestureSlot` options grouped by hand
- Menu structure:
  ```
  ▸ Left Hand
      Index
      Middle
      Ring
  ▸ Right Hand
      Index
      Middle
      Ring
  ▸ Both Hands
      Index
      Middle
      Ring
  ───────
  Clear Gesture
  ```
- For triplet parameters: auto-assign as `.parameterTriplet` and only show Left/Right options (not Both)
- For scalar parameters: show all 9 options

### 8. Music + Gesture Integration (Delegation)

**How it works today**: Music modulation runs independently in `Renderer.swift` every frame. It reads the current parameter value, applies music-driven offset, and writes the modulated value. Gestures set target values through `RenderSettings` which are interpolated separately. They compose naturally — gesture sets the base, music adds modulation.

**What changes**: Nothing fundamental. The new per-hand binding model doesn't alter the parameter operation dispatch or music modulation pipeline. A parameter can have:
- A gesture binding (left/right/both slot) setting its target
- A music reactive mapping modulating it on top
- An animation keyframe driving its base

These three sources already compose correctly. The revamp just reorganizes *which hand/finger* drives the gesture — the downstream parameter dispatch (`ParameterOperationDispatcher`) and music modulation are untouched.

**Triplets + Music**: Each component of a triplet (X, Y, Z) can independently have music reactivity. When the user gesture-drags a triplet, the gesture sets all 3 targets; music modulation (if assigned to any of those params) adds its offset independently per-component. No special handling needed.

---

## Implementation Order

1. **FingerGestureAction.swift**: Add `GestureHandMode`, `FingerDigit`, `GestureSlot`. Add `.translate` to `FingerGestureAction`. Update `availableBindings(for:handMode:)`. Keep `FingerPair` temporarily for backward compat.

2. **RenderSettings.swift**: Replace 4 binding slots with 9. Add migration from old keys. Update `binding(for:)`, `slot(for:)`, sanitizer. Remove old `bindingForDigit`/`digitForBinding`.

3. **UISettingsCache.swift**: Mirror 9 slots. Update `setBinding`/`slot(for:)` helpers.

4. **GestureController.swift**: Restructure `processGestures()` into 3 loops (both/left/right). Unify single-hand drag into `processSingleHandDrag`. Remove `processRightIndexDrag`. Remove `tripletDrag*` separate state. Add `singleHandDragState` dict. Update suppression/sync logic.

5. **GestureSettingsView.swift**: New UI with 3 hand sections, 3 finger pickers each, hand-mode-filtered available bindings.

6. **ContentView.swift**: Remove old finger picker calls, wire up new view.

7. **FormulaParamsEditor.swift**: Update gesture assignment menu to use `GestureSlot`.

8. **Compile check & test**.

---

## Backward Compatibility

- **UserDefaults**: Old keys (`indexFingerBinding`, etc.) are migrated on first read. New keys use `leftIndex`, `rightIndex`, `bothIndex` prefix pattern.
- **Presets (.threshscene)**: Gesture bindings are NOT stored in presets (they're user preferences stored in UserDefaults), so no preset format change needed.
- **FingerPair**: Deprecated but kept temporarily until all references are migrated. Can be removed once FormulaParamsEditor and all callers use `GestureSlot`.

---

## Verification

- [ ] All 9 slots can be set and persist across app restarts
- [ ] Changing fractal type sanitizes all 9 slots correctly
- [ ] Left-hand pinch-drag works for translate, scalar, and triplet bindings
- [ ] Right-hand pinch-drag works for translate, scalar, and triplet bindings
- [ ] Both-hand pull-apart works for grab, scalar, and core bindings
- [ ] Triplet bindings appear as single items in pickers (not X/Y/Z separately)
- [ ] FormulaParamsEditor gesture assignment correctly targets hand+finger slots
- [ ] Music reactivity composes correctly with gesture-bound parameters
- [ ] Old UserDefaults migrate correctly to new slots
- [ ] Compile succeeds with no warnings from deprecated FingerPair usage
