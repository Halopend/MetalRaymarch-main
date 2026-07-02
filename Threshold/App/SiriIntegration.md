# Siri Integration for Threshold

This document describes the Siri integration implementation for Threshold, an iOS/macOS/visionOS app that visualizes fractals and serves as a music visualizer.

## Overview

Threshold now supports Siri controls through App Intents, allowing users to:
- Toggle animation playback
- Adjust lighting intensity and mode
- Control animation tempo and damping
- Apply mood presets
- Apply space transformation effects

## Siri Commands Available

### 1. Toggle Animation
- **Phrases**: "Toggle animation", "Play/pause fractal animation", "Start/stop Threshold animation"
- **Controls**: Play/pause the current fractal animation
- **Intent**: `ToggleAnimationIntent`

### 2. Set Lighting Intensity
- **Phrases**: "Set lighting intensity", "Adjust lights", "Change lighting in Threshold"
- **Controls**: Adjust lighting intensity (0.0-1.0) and lighting mode
- **Intent**: `SetLightingIntensityIntent`

### 3. Adjust Tempo
- **Phrases**: "Adjust tempo", "Set animation speed", "Change tempo in Threshold"
- **Controls**: Set animation tempo (0.1-5.0) and damping (0.0-1.0)
- **Intent**: `AdjustTempoIntent`

### 4. Set Mood
- **Phrases**: "Set mood", "Apply mood preset", "Change mood in Threshold"
- **Controls**: Apply mood presets (Calm, Energetic, Mysterious, Cosmic, Abstract) with intensity
- **Intent**: `SetMoodIntent`

### 5. Apply Space Effect
- **Phrases**: "Apply space effect", "Add space transformation", "Apply cosmic effect"
- **Controls**: Apply various space transformation effects with intensity
- **Intent**: `ApplySpaceEffectIntent`

## Implementation Details

### App Intents Structure

The implementation includes:

1. **App Entities**:
   - `SceneEntity`: Represents fractal scenes
   - `MusicPresetEntity`: Represents music presets

2. **Entity Queries**:
   - `SceneEntityQuery`: Resolves scene entities
   - `MusicPresetEntityQuery`: Resolves music preset entities

3. **App Enums**:
   - `AnimationSpeed`: Speed options (slow, normal, fast, turbo)
   - `LightingMode`: Lighting modes (ambient, directional, point, volumetric)
   - `MoodPreset`: Mood presets (calm, energetic, mysterious, cosmic, abstract)

4. **Main App Intents**:
   - `ToggleAnimationIntent`: Play/pause animation
   - `SetLightingIntensityIntent`: Control lighting
   - `AdjustTempoIntent`: Control animation speed
   - `SetMoodIntent`: Apply mood presets
   - `ApplySpaceEffectIntent`: Apply space effects

5. **App Shortcuts Provider**:
   - `ThresholdAppShortcuts`: Registers all Siri shortcuts

### Info.plist Changes

The following keys were added to `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Threshold analyzes live audio input to create music-reactive fractal visualizations.</string>
<key>NSAppIntentsUsageDescription</key>
<string>Threshold uses App Intents to enable Siri controls for play/pause animations, lighting intensity, tempo/damping, mood-based tuning, and space transformation effects.</string>
<key>NSAppIntentsSupported</key>
<true/>
```

## Usage

### Testing Siri Integration

1. **Build and Run**: Build the app in Xcode
2. **Test in Shortcuts**: Open the Shortcuts app to test the intents
3. **Test with Siri**: Use Siri with phrases like "Hey Siri, toggle animation"

### Development Notes

- All intents are marked as `async throws` for proper error handling
- Each intent includes a `parameterSummary` for better Shortcuts UI
- Intents are registered with descriptive phrases for better Siri recognition
- The implementation follows App Intents best practices

## Future Enhancements

Potential future Siri features:
- Voice command recognition for specific fractal types
- Music-reactive controls (bass, treble, tempo)
- Scene switching commands
- Export/share commands
- Custom gesture voice commands

## Dependencies

This implementation requires:
- iOS 16+ (for App Intents)
- Xcode 15+ (for App Intents support)
- Proper entitlements for microphone access

## Troubleshooting

### Common Issues

1. **Siri not recognizing commands**: Ensure phrases include the app name
2. **Intents not appearing in Shortcuts**: Check that `NSAppIntentsSupported` is set to `true`
3. **Permission issues**: Ensure proper usage descriptions are in Info.plist

### Debugging

1. Use Xcode's App Intents preview to test intents
2. Check Console for App Intents-related errors
3. Test in the Shortcuts app before using with Siri