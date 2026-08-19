# Threshold — macOS App Review Notes

Use the following notes in App Store Connect for the macOS submission.

## Review access

Threshold does not require an account, subscription, in-app purchase, or demo
credentials. All primary features are available immediately after the safety
and privacy setup screens.

## Permissions and audio

- Microphone access is optional and is requested only when the reviewer enables
  microphone-reactive visuals or chooses to start the microphone during setup.
- Microphone samples are analyzed in memory to drive visuals. They are not
  recorded, saved, or uploaded.
- This release does not capture the screen or system-output audio and does not
  use ScreenCaptureKit.
- Apple Music permission is requested only if the reviewer uses Apple Music
  browsing/playback features.

## Anonymous analytics

Anonymous analytics are off by default and remain off unless the reviewer
explicitly enables them during setup or in Settings → Sharing. When enabled,
aggregate usage and performance records are sent to the app's CloudKit public
database. The in-app setup and Settings screens link to the privacy policy.

## Custom scene formulas

Custom scenes are always available. The feature allows the user to create or
import a local `.threshfx` scene formula. Formula
source is always visible and editable in the app. Threshold validates the
formula and compiles it locally with Apple's public Metal API
`MTLDevice.makeLibrary(source:)` solely to render the user's scene.

Threshold does not download executable code, provide a remote code catalog or
store, expose native macOS APIs to formulas, or execute formulas outside its
Metal rendering template. The feature is analogous to a document editor whose
document contains user-authored shader source.

Suggested review path: open Metal DE Studio to inspect or edit the source
before compiling it.

## Privacy policy

The policy is available at:
https://github.com/Halopend/MetalRaymarch-main/blob/main/PRIVACY_POLICY.md

Confirm this URL is publicly reachable before submitting the build.
