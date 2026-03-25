# Persistence Key Ownership by Domain

This note documents ownership of persisted key-space by domain. Feature modules should call typed persistence APIs and avoid raw key strings.

## Domain ownership

- `cfg.geometry` → geometry/fractal shape config.
- `cfg.quality` → quality and rendering tradeoff config.
- `cfg.color` → gradient/coloring config.
- `cfg.lighting` → lighting and post-processing config.
- `cfg.audioReactive` → audio-reactivity scalar/mapping config.
- `cfg.gesture` → hand/gesture binding config.
- `cfg.safetyBubble` → comfort/safety bubble config.
- `cfg.display` → display and compositor config.
- `cfg.music` → music integration config:
  - service preferences (`preferredServiceID`)
  - service fallback priority (`servicePriority`)
  - saved music-reactive presets (`[MusicReactivePreset]`)

## Key ownership policy

- Feature/UI modules (`Threshold/Audio`, `Threshold/Views`, etc.) should never call `UserDefaults.standard` directly.
- Persistence ownership lives in typed facades (`SettingsPersistence` and other persistence stores).
- Lint check: `scripts/check_userdefaults_usage.sh` enforces this boundary in CI.

## Legacy key migration (music)

`SettingsPersistence` migrates and then clears these legacy keys on read:

- `music.preferredServiceID`
- `music.servicePriority`
- `musicReactivePresets`

This preserves user data while consolidating ownership under `cfg.music`.
