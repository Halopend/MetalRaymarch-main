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

        // Use cached rotation matrix (constant, computed once in init)
        let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
        let scaleMatrix = matrix4x4_scale(smoothedScale, smoothedScale, smoothedScale)

        let modelMatrix = translationMatrix * cachedRotationMatrix * scaleMatrix

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
        cachedModelMatrix = modelMatrix

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)
            let inverseProjection = projection.inverse

            let modelView = viewMatrix * modelMatrix
            let inverseModelView = modelView.inverse
            let inverseView = viewMatrix.inverse

            let colorSchemeParams = settingsSnapshot.colorSchemeParams

            // Get fovea center from the view's texture map (normalized 0-1)
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: inverseModelView,
                            inverseProjectionMatrix: inverseProjection,
                            viewMatrix: viewMatrix,
                            inverseViewMatrix: inverseView,
                            time: frameTime,
                            minDistance: settingsSnapshot.minDistance,
                            fractalScale: settingsSnapshot.fractalScale,
                            fractalIterations: Int32(settingsSnapshot.fractalIterations),
                            maxRaySteps: Int32(settingsSnapshot.maxRaySteps),
                            colorMix: animatedColorMix,
                            glowIntensity: animatedGlow,
                            foldingLimit: settingsSnapshot.foldingLimit,
                            sphereRadius: settingsSnapshot.sphereRadius,
                            safetyBubbleRadius: settingsSnapshot.safetyBubbleRadius,
                            safetyBubbleEnabled: settingsSnapshot.safetyBubbleEnabled ? 1 : 0,
                            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
                            colorIterations: settingsSnapshot.colorIterations,
                            limitFlash: settingsSnapshot.limitFlash,
                            showHUD: settingsSnapshot.showHUD ? 1 : 0,
                            activeGesture: Int32(settingsSnapshot.activeGestureIndex),
                            gestureSpread: settingsSnapshot.gestureSpread,
                            fractalType: settingsSnapshot.fractalType.rawValue,
                            lightingMode: settingsSnapshot.lightingMode.rawValue,
                            audioLevel: settingsSnapshot.audioLevel,
                            bassLevel: settingsSnapshot.bassLevel,
                            midLevel: settingsSnapshot.midLevel,
                            trebleLevel: settingsSnapshot.trebleLevel,
                            beatIntensity: settingsSnapshot.beatIntensity,
                            visualizerMode: settingsSnapshot.visualizerMode,
                            visualizerIntensity: settingsSnapshot.visualizerIntensity,
                            fogIntensity: settingsSnapshot.colorSchemeParams.fogIntensity,
                            lightingSoftness: settingsSnapshot.lightingSoftness,
                            maxViewDistance: RenderSettings.maxViewDistance,
                            logDepthScale: RenderSettings.logDepthScale,
                            depthMissValue: RenderSettings.depthMissValue,
                            // === GMT-FRACTALS OPTIMIZATIONS ===
                            stepMultiplier: settingsSnapshot.stepMultiplier,
                            boundingSphereRadius: 0.0,  // Disabled: Mandelbox extent varies with minDistance/scale; needs dynamic radius
                            blendFactor: settingsSnapshot.isGeometryGestureActive ? 1.0 : (settingsSnapshot.geometryState == .stable ? 0.1 : 0.5),
                            jitterOffset: currentJitterOffset(),
                            accumulationFrame: Int32(accumulationFrameCount),
                            pad_gmt: 0.0,
                            precomputedFractal: precomputedFractal,
                            precomputedLighting: precomputedLighting,
                            colorScheme: colorSchemeParams)
        }

        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if drawable.views.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }

//        rotation += 0.01
    }
}
