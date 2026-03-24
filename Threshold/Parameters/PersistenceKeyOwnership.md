# Persistence Key Ownership by Domain

This note documents which domain owns which persisted key-space. Feature modules should depend on typed persistence APIs and avoid raw key strings.

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
  - service selection and priority (`MusicPreferences`)
  - saved music-reactive presets (`[MusicReactivePreset]`)

## Legacy key migration (music)

`SettingsPersistence` migrates and then clears these legacy keys on read:

- `music.preferredServiceID`
- `music.servicePriority`
- `musicReactivePresets`

This preserves user data while consolidating ownership under `cfg.music`.
