# Siri Integration for Threshold

How Threshold exposes Siri / App Shortcuts / Spotlight controls, for a fractal
visualizer that doubles as a music visualizer.

> **Source of truth:** [`AppIntents.swift`](AppIntents.swift). This doc describes
> the intents that actually ship there. It is kept in sync with that file — if you
> add or rename an intent, update this doc in the same change.

## What actually ships

The live intents live in **`Threshold/App/AppIntents.swift`** and are registered
by **`ThresholdAppShortcutsProvider`** (an `AppShortcutsProvider`). They fall into
four groups:

### Animation transport
| Intent | Title | Action |
|--------|-------|--------|
| `PlayAnimationIntent`  | "Play animation"  | `animationManager?.play()` |
| `PauseAnimationIntent` | "Pause animation" | `animationManager?.pause()` |
| `StopAnimationIntent`  | "Stop animation"  | `animationManager?.stop()` |

### Audio-reactivity controls
| Intent | Title | Action |
|--------|-------|--------|
| `ToggleAudioReactivityIntent`  | "Toggle audio reactivity"  | flips `renderSettings.fractalAudioReactiveEnabled` |
| `EnableAudioReactivityIntent`  | "Enable audio reactivity"  | sets it `true` |
| `DisableAudioReactivityIntent` | "Disable audio reactivity" | sets it `false` |
| `IncreaseAudioAmountIntent`    | "Increase audio sensitivity" | `fractalAudioAmount += 0.1` (cap 1.0) |
| `DecreaseAudioAmountIntent`    | "Decrease audio sensitivity" | `fractalAudioAmount -= 0.1` (floor 0.0) |
| `IncreaseBeatPunchIntent`      | "Increase beat punch"      | `fractalBeatPunch += 0.1` (cap 1.0) |
| `DecreaseBeatPunchIntent`      | "Decrease beat punch"      | `fractalBeatPunch -= 0.1` (floor 0.0) |

### Music transport (Apple Music / Spotify via `MusicService`)
| Intent | Title | Action |
|--------|-------|--------|
| `ToggleMusicPlaybackIntent` | "Play or pause music" | `musicService.togglePlayPause()` |
| `NextTrackIntent`           | "Next track"          | `musicService.next()` |
| `PreviousTrackIntent`       | "Previous track"      | `musicService.previous()` |
| `NowPlayingIntent`          | "What's playing"      | reads `musicService.nowPlaying` (query-only, does not open the app) |

### Parameterized intents
| Intent | Title | Parameter |
|--------|-------|-----------|
| `SwitchFractalTypeIntent`   | "Switch fractal"        | `fractal: FractalTypeAppEnum` |
| `SetAudioSensitivityIntent` | "Set audio sensitivity" | `percent: Int` (0–100, default 60) |

`FractalTypeAppEnum` (an `AppEnum`) is the only app enum that ships. Its cases
mirror `FractalModelType`'s selectable set (mandelbox, mandelbulb, mandelbulbJulia,
menger, quaternionJulia, octahedron, mengerSphere, theliPseudoKleinian, kleinian),
and `.modelType` maps each case back to the engine enum by matching
`FractalModelType.descriptor.codableString`.

There are **no** `AppEntity` types and **no** `EntityQuery` types in the shipping
implementation.

## Registered voice phrases (the 10-shortcut cap)

`AppShortcutsProvider` registers a **maximum of 10** App Shortcuts — anything past
the 10th is silently dropped. Every intent above is still reachable in the
Shortcuts app and Spotlight; the provider list is just the curated zero-config
*voice* set. The current 10 (in order), each phrased with `\(.applicationName)`:

1. **Play** — `PlayAnimationIntent`
2. **Pause** — `PauseAnimationIntent`
3. **Toggle Audio** — `ToggleAudioReactivityIntent`
4. **Set Sensitivity** — `SetAudioSensitivityIntent` (parameterized)
5. **Boost Beat** — `IncreaseBeatPunchIntent`
6. **Switch Fractal** — `SwitchFractalTypeIntent` (parameterized)
7. **Play/Pause Music** — `ToggleMusicPlaybackIntent`
8. **Next Track** — `NextTrackIntent`
9. **Previous Track** — `PreviousTrackIntent`
10. **Now Playing** — `NowPlayingIntent`

If you add a shortcut here, drop or reorder one — the list is at the cap. Lead with
the highest-value voice commands (parameterized ones especially).

## Implementation notes

- Every intent's `perform()` is `@MainActor` and guards on `AppModel.shared`
  (`static nonisolated(unsafe) var shared: AppModel?`), returning a "Threshold app
  not available" dialog when it's nil.
- Most intents set `openAppWhenRun = true`; `NowPlayingIntent` sets it `false`
  (pure query).
- Music transport intents are **fire-and-forget** — `next`/`previous`/`toggle`
  run async in the provider, so `nowPlaying` / `isPlaying` still reflect the
  pre-action state inside `perform()`. The dialogs deliberately report the *action*
  ("Skipping to the next track"), not a state that may be stale by the time Siri
  speaks.

### Info.plist keys (present in [`Info.plist`](Info.plist))

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Threshold analyzes live audio input to create music-reactive fractal visualizations.</string>
<key>NSAppIntentsUsageDescription</key>
<string>Threshold uses App Intents to enable Siri controls for play/pause animations, lighting intensity, tempo/damping, mood-based tuning, and space transformation effects.</string>
<key>NSAppIntentsSupported</key>
<true/>
```

> Note: the `NSAppIntentsUsageDescription` string still describes an older intent
> set (lighting/tempo/mood/space). It's user-facing copy, not code — update it to
> match the shipping intents above when convenient.

## Quarantined WIP — do not use as reference

`Threshold/App/Intents/ThresholdAppIntents.swift` contains an **older, unfinished**
App Intents design (mood presets, lighting/tempo intents, `SceneEntity` /
`MusicPresetEntity`, `ThresholdAppShortcuts`). It is wrapped in
`#if ENABLE_WIP_APP_INTENTS` — a flag that is **not defined anywhere**, so none of
it compiles or registers. It was quarantined 2026-07-01 because its folder is
auto-included in every target by the synchronized group and its errors were
breaking all builds. Ignore it unless you intend to finish and un-gate it; the
shipping surface is entirely in `AppIntents.swift`.

## Requirements

- Deployment target **26.0** (macOS 26 / visionOS 26 / iPadOS 26). The codebase
  uses OS-26 APIs throughout; App Intents themselves predate this, but the app's
  floor is 26.
- Microphone usage description (above) for the audio-reactive path.

## Testing

1. Build and run (see [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) for the
   toolchain pin).
2. Open the **Shortcuts** app to see all intents (not just the 10 voice phrases).
3. Try Siri with the app name in the phrase, e.g. "Hey Siri, play music in
   Threshold" or "Hey Siri, switch fractal in Threshold".
