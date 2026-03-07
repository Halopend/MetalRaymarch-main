@preconcurrency import CompositorServices
import Foundation

extension Renderer {
    func updateGameState(drawable: LayerRenderer.Drawable, settingsSnapshot: RenderSettingsSnapshot) {
        /// Update any game state before rendering

        // Use already-smoothed position from settings (interpolated above)
        // Scale gets its own smoothing since it's not gesture-controlled
        let smoothSpeed: Float = 15.0
        let smoothFactor = 1.0 - exp(-smoothSpeed * cachedDeltaTime)
        let smoothedPosition = settingsSnapshot.position  // Already smoothed by interpolateToTargets
        smoothedScale = smoothedScale + (settingsSnapshot.scale - smoothedScale) * smoothFactor

        // Use cached base rotation matrix (constant −90° Y) combined with user world rotation
        let userRotationMatrix = matrix4x4_from_quaternion(settingsSnapshot.worldRotation)
        let combinedRotationMatrix = userRotationMatrix * cachedRotationMatrix
        
        let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
        // Combine base scale with detail scale factor (from grab gesture)
        let effectiveScale = smoothedScale * settingsSnapshot.detailScale
        let traceScale = max(effectiveScale, 0.15)
        let targetMaxViewDistance = min(80.0, RenderSettings.maxViewDistance / traceScale)
        let maxViewDistanceSpeed: Float = (targetMaxViewDistance > smoothedMaxViewDistance) ? 30.0 : 10.0
        let maxViewDistanceBlend = 1.0 - exp(-maxViewDistanceSpeed * cachedDeltaTime)
        smoothedMaxViewDistance += (targetMaxViewDistance - smoothedMaxViewDistance) * maxViewDistanceBlend
        let maxViewDistance = max(4.0, min(80.0, smoothedMaxViewDistance))
        let scaleMatrix = matrix4x4_scale(effectiveScale, effectiveScale, effectiveScale)

        let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix

        // Use raw device anchor transform (no smoothing) to ensure compositor-predicted pose is used
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        // One-time logging of device anchor to verify position tracking is working
        if !hasLoggedDeviceAnchorInfo, let anchor = drawable.deviceAnchor {
            hasLoggedDeviceAnchorInfo = true
            let transform = anchor.originFromAnchorTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            if RENDERER_DEBUG {
                print("📍 Device anchor first frame:")
                print("   Position: (\(position.x), \(position.y), \(position.z))")
                print("   isTracked: \(anchor.isTracked)")
                // If position is exactly (0,0,0), world sensing permission may not be granted
                if position.x == 0 && position.y == 0 && position.z == 0 {
                    print("   ⚠️ Position is origin - world sensing may not be authorized!")
                }
            }
        }

        // === PRECOMPUTE FRAME-UNIFORM VALUES ===
        // These are computed once per frame on CPU, shared by all pixels
        // Eliminates expensive per-pixel calculations like powr() and CameraPath()
        let frameTime = Float(appModel.clock.time)  // Cache once — used in uniforms + precomputed
        let precomputedFractal = Self.makePrecomputedFractal(from: settingsSnapshot)
        let precomputedLighting = Self.makePrecomputedLighting(
            time: frameTime,
            lightingMode: settingsSnapshot.lightingMode,
            audioLevel: settingsSnapshot.audioLevel,
            bassLevel: settingsSnapshot.bassLevel,
            midLevel: settingsSnapshot.midLevel,
            trebleLevel: settingsSnapshot.trebleLevel,
            beatIntensity: settingsSnapshot.beatIntensity
        )
        let precomputedAudio = Self.makePrecomputedAudio(from: settingsSnapshot)
        let precomputedFog = Self.makePrecomputedFog(from: settingsSnapshot)

        // Hoist lightingWave out of per-eye loop — sin() is identical for both eyes
        let baseColorMix = settingsSnapshot.colorMix
        let baseGlow = settingsSnapshot.colorSchemeParams.glowIntensity
        let lightingWave = sin(frameTime * 1.2)
        let animatedColorMix = settingsSnapshot.lightingPlay ? min(max(baseColorMix + lightingWave * 0.08, 0.0), 1.0) : baseColorMix
        let animatedGlow = settingsSnapshot.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow

        // Cache frame-level values for reuse in encodeAdaptiveCompute (avoids recomputing per eye)
        cachedFrameTime = frameTime
        cachedPrecomputedFractal = precomputedFractal
        cachedPrecomputedLighting = precomputedLighting
        cachedPrecomputedAudio = precomputedAudio
        cachedPrecomputedFog = precomputedFog
        cachedModelMatrix = modelMatrix
        cachedMaxViewDistance = maxViewDistance
        let boundingSphereRadius = settingsSnapshot.estimatedBoundingSphereRadius

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)

            let modelView = viewMatrix * modelMatrix

            let colorSchemeParams = settingsSnapshot.colorSchemeParams

            // Scale-relative safety bubble: divide radius by effectiveScale so it stays
            // constant in user/world space regardless of detail zoom level.
            let scaleCorrectedBubbleRadius = settingsSnapshot.safetyBubbleRadius / max(effectiveScale, 0.001)
            let scaleCorrectedFadeWidth = settingsSnapshot.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

            // Get fovea center from the view's texture map (normalized 0-1)
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: modelView.inverse,
                            time: frameTime,
                            minDistance: settingsSnapshot.minDistance,
                            fractalScale: settingsSnapshot.fractalScale,
                            fractalIterations: Int32(settingsSnapshot.fractalIterations),
                            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                            maxViewDistance: maxViewDistance,
                            colorMix: animatedColorMix,
                            glowIntensity: animatedGlow,
                            foldingLimit: settingsSnapshot.foldingLimit,
                            sphereRadius: settingsSnapshot.sphereRadius,
                            safetyBubbleRadius: scaleCorrectedBubbleRadius,
                            // Mandelbulb: force safety bubble off — its compact geometry
                            // doesn’t need a safety carve-out and the blend/fade creates
                            // visible artifacts when zooming deep into surface detail.
                            safetyBubbleEnabled: (settingsSnapshot.fractalType == .mandelbulb) ? 0 : (settingsSnapshot.safetyBubbleEnabled ? 1 : 0),
                            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
                            safetyBubbleFadeEnabled: settingsSnapshot.safetyBubbleFadeEnabled ? 1 : 0,
                            safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                            safetyBubbleStrength: (settingsSnapshot.fractalType == .mandelbulb) ? 0.0 : settingsSnapshot.safetyBubbleStrength,
                            colorIterations: settingsSnapshot.colorIterations,
                            limitFlash: settingsSnapshot.limitFlash,
                            showHUD: settingsSnapshot.showHUD ? 1 : 0,
                            activeGesture: Int32(settingsSnapshot.activeGestureIndex),
                            fractalType: settingsSnapshot.fractalType.rawValue,
                            formulaParams: settingsSnapshot.formulaParams,
                            lightingSoftness: settingsSnapshot.lightingSoftness,
                            // === GMT-FRACTALS OPTIMIZATIONS ===
                            stepMultiplier: settingsSnapshot.stepMultiplier,
                            boundingSphereRadius: boundingSphereRadius,
                            jitterOffset: currentJitterOffset(),
                            precomputedFractal: precomputedFractal,
                            precomputedLighting: precomputedLighting,
                            precomputedAudio: precomputedAudio,
                            precomputedFog: precomputedFog,
                            colorScheme: colorSchemeParams)
        }

        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }

//        rotation += 0.01
    }
}
