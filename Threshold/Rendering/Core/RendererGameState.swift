@preconcurrency import CompositorServices
import Foundation
import simd

struct RendererPreparedEyeState {
    var modelView: matrix_float4x4 = matrix_identity_float4x4
    var inverseModelView: matrix_float4x4 = matrix_identity_float4x4
    var projection: matrix_float4x4 = matrix_identity_float4x4
    var floorPlane: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 0)
    var floorCenterRadius: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
}

struct RendererFramePreparation {
    var frameTime: Float
    var precomputedFractal: PrecomputedFractalParams
    var precomputedLighting: PrecomputedLighting
    var precomputedAudio: PrecomputedAudio
    var precomputedFog: PrecomputedFog
    var modelMatrix: matrix_float4x4
    var maxViewDistance: Float
    var effectiveScale: Float
    var animatedColorMix: Float
    var animatedGlow: Float
    var perEye: [RendererPreparedEyeState]
}

private enum FloorCircleGeometry {
    static let fallbackEyeHeightMeters: Float = 1.55
}

extension Renderer {
    private static func makeFloorCircleUniforms(
        modelMatrix: matrix_float4x4,
        effectiveScale: Float,
        deviceTransform: matrix_float4x4,
        platformRadius: Float
    ) -> (plane: SIMD4<Float>, centerRadius: SIMD4<Float>) {
        let headWorldPosition = SIMD3<Float>(
            deviceTransform.columns.3.x,
            deviceTransform.columns.3.y,
            deviceTransform.columns.3.z
        )
        let hasTrackedFloorHeight = headWorldPosition.y > 0.25
        let eyeHeightMeters = hasTrackedFloorHeight ? headWorldPosition.y : FloorCircleGeometry.fallbackEyeHeightMeters
        let floorY = hasTrackedFloorHeight ? Float(0.0) : headWorldPosition.y - eyeHeightMeters
        let floorCenterWorld = SIMD3<Float>(headWorldPosition.x, floorY, headWorldPosition.z)

        let inverseModelMatrix = modelMatrix.inverse
        let centerHomogeneous = inverseModelMatrix * SIMD4<Float>(floorCenterWorld.x, floorCenterWorld.y, floorCenterWorld.z, 1.0)
        let centerHomogeneousW = abs(centerHomogeneous.w) > 1e-6 ? centerHomogeneous.w : 1.0
        let floorCenterModel = SIMD3<Float>(centerHomogeneous.x, centerHomogeneous.y, centerHomogeneous.z) / centerHomogeneousW

        let rawNormal = modelMatrix.transpose * SIMD4<Float>(0.0, 1.0, 0.0, 0.0)
        let rawNormalModel = SIMD3<Float>(rawNormal.x, rawNormal.y, rawNormal.z)
        let normalLength = simd_length(rawNormalModel)
        let floorNormalModel = normalLength > 1e-6 ? rawNormalModel / normalLength : SIMD3<Float>(0.0, 1.0, 0.0)
        let floorPlane = SIMD4<Float>(
            floorNormalModel.x,
            floorNormalModel.y,
            floorNormalModel.z,
            -simd_dot(floorNormalModel, floorCenterModel)
        )

        let floorRadiusMeters = max(0.5, platformRadius)
        let floorRadiusModel = floorRadiusMeters / max(effectiveScale, 0.001)
        let floorCenterRadius = SIMD4<Float>(floorCenterModel.x, floorCenterModel.y, floorCenterModel.z, floorRadiusModel)

        return (floorPlane, floorCenterRadius)
    }

    func updateGameState(drawable: LayerRenderer.Drawable, settingsSnapshot: RenderSettingsSnapshot) -> RendererFramePreparation {
        /// Update any game state before rendering

        // Use already-smoothed position from settings (interpolated above)
        // Scale gets its own smoothing since it's not gesture-controlled
        let smoothSpeed: Float = 15.0
        let smoothFactor = 1.0 - exp(-smoothSpeed * cachedDeltaTime)
        let smoothedPosition = settingsSnapshot.position  // Already smoothed by interpolateToTargets
        smoothedScale = smoothedScale + (settingsSnapshot.scale - smoothedScale) * smoothFactor

        // === SPRING BLOB PHYSICS ===
        // Tick the spring each frame (only when spring blob mode is enabled).
        if appModel.renderSettings.useSpringBlob {
            let springDelta = appModel.renderSettings.tickSpring(dt: cachedDeltaTime)
            if simd_length_squared(springDelta) > 1e-8 {
                let settings = appModel.renderSettings
                if settings.isAnimationPlaying {
                    settings.manualOffsetPosition = settings.manualOffsetPosition + springDelta
                } else {
                    settings.targetPosition = settings.targetPosition + springDelta
                }
            }
        }

        // Use cached base rotation matrix (constant −90° Y) combined with user world rotation
        let userRotationMatrix = matrix4x4_from_quaternion(settingsSnapshot.worldRotation)
        let combinedRotationMatrix = userRotationMatrix * cachedRotationMatrix
        
        let translationMatrix = matrix4x4_translation(smoothedPosition.x, smoothedPosition.y, smoothedPosition.z)
        // Combine base scale with detail scale factor (from grab gesture)
        let effectiveScale = smoothedScale * settingsSnapshot.detailScale
        let isKleinianFamily =
            settingsSnapshot.fractalType == .kleinian ||
            settingsSnapshot.fractalType == .theliPseudoKleinian

        // Kleinian formulas benefit from a larger trace horizon when zooming out;
        // otherwise they look artificially bounded and fade away too early.
        let traceScaleFloor: Float = isKleinianFamily ? 0.02 : 0.15
        let traceScale = max(effectiveScale, traceScaleFloor)
        let maxViewDistanceCap: Float = isKleinianFamily ? 420.0 : 80.0
        let baseViewDistance: Float = isKleinianFamily
            ? (RenderSettings.maxViewDistance * 2.0)
            : RenderSettings.maxViewDistance
        let targetMaxViewDistance = min(maxViewDistanceCap, baseViewDistance / traceScale)
        let maxViewDistanceSpeed: Float = (targetMaxViewDistance > smoothedMaxViewDistance) ? 30.0 : 10.0
        let maxViewDistanceBlend = 1.0 - exp(-maxViewDistanceSpeed * cachedDeltaTime)
        smoothedMaxViewDistance += (targetMaxViewDistance - smoothedMaxViewDistance) * maxViewDistanceBlend
        let maxViewDistance = max(4.0, min(maxViewDistanceCap, smoothedMaxViewDistance))
        let scaleMatrix = matrix4x4_scale(effectiveScale, effectiveScale, effectiveScale)

        let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix

        // Use raw device anchor transform (no smoothing) to ensure compositor-predicted pose is used
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let floorCircle = Self.makeFloorCircleUniforms(
            modelMatrix: modelMatrix,
            effectiveScale: effectiveScale,
            deviceTransform: deviceTransform,
            platformRadius: settingsSnapshot.platformRadius
        )

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
            beatIntensity: settingsSnapshot.beatIntensity,
            vibrance: settingsSnapshot.colorSchemeParams.vibrance,
            lightingSoftness: settingsSnapshot.lightingSoftness
        )
        let precomputedAudio = Self.makePrecomputedAudio(from: settingsSnapshot)
        var precomputedFog = Self.makePrecomputedFog(from: settingsSnapshot)
        if isKleinianFamily {
            // Keep atmospheric depth while avoiding distant wash-out during deep zoom-out.
            let baseFog = precomputedFog.fog.x
            if baseFog > 1e-6 {
                let fogScale = min(1.0, max(0.08, traceScale / 0.15))
                let fogIntensity = baseFog * fogScale
                let invFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
                precomputedFog = PrecomputedFog(
                    fog: SIMD4<Float>(fogIntensity, invFog, 0.0, 0.0),
                    color: precomputedFog.color
                )
            }
        }

        // Hoist lightingWave out of per-eye loop — sin() is identical for both eyes
        let baseColorMix = settingsSnapshot.colorMix
        let baseGlow = settingsSnapshot.colorSchemeParams.glowIntensity
        let lightingWave = sin(frameTime * 1.2)
        let animatedColorMix = settingsSnapshot.lightingPlay ? min(max(baseColorMix + lightingWave * 0.08, 0.0), 1.0) : baseColorMix
        let animatedGlow = settingsSnapshot.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow

        let boundingSphereRadius = settingsSnapshot.estimatedBoundingSphereRadius
        var preparedEyeStates = Array(repeating: RendererPreparedEyeState(), count: drawable.views.count)

        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let view = drawable.views[viewIndex]
            let viewMatrix = (deviceTransform * view.transform).inverse
            let projection = drawable.computeProjection(viewIndex: viewIndex)

            let modelView = viewMatrix * modelMatrix
            let inverseModelView = modelView.inverse

            preparedEyeStates[viewIndex] = RendererPreparedEyeState(
                modelView: modelView,
                inverseModelView: inverseModelView,
                projection: projection,
                floorPlane: floorCircle.plane,
                floorCenterRadius: floorCircle.centerRadius
            )

            let colorSchemeParams = settingsSnapshot.colorSchemeParams

            // Scale-relative safety bubble: divide radius by effectiveScale so it stays
            // constant in user/world space regardless of detail zoom level.
            let scaleCorrectedBubbleRadius = settingsSnapshot.safetyBubbleRadius / max(effectiveScale, 0.001)
            let scaleCorrectedFadeWidth = settingsSnapshot.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

            // Previous frame's view-proj (model → prev clip) for the temporal
            // depth warm-start. updateGameState runs before finishFragmentPass
            // rotates these, so they still hold last frame's matrices here.
            let prevViewProj = viewIndex < previousViewProjMatrices.count
                ? previousViewProjMatrices[viewIndex]
                : matrix_identity_float4x4

            // Get fovea center from the view's texture map (normalized 0-1)
            return Uniforms(projectionMatrix: projection,
                            modelViewMatrix: modelView,
                            inverseModelViewMatrix: inverseModelView,
                            previousViewProjMatrix: prevViewProj,
                            previousInvViewProjMatrix: prevViewProj.inverse,
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
                            activeGesture: Int32(settingsSnapshot.activeGestureIndex),
                            // Patched after prepareFragmentPassPlan once the MetalFX
                            // input size (renderResolution) is known.
                            warmStartEnabled: 0,
                            fractalType: settingsSnapshot.fractalType.rawValue,
                            lightingSoftness: settingsSnapshot.lightingSoftness,
                            sphericalInversionMode: settingsSnapshot.sphericalInversionMode.rawValue,
                            sphericalInversionRadius: settingsSnapshot.sphericalInversionRadius,
                            stepMultiplier: settingsSnapshot.stepMultiplier,
                            boundingSphereRadius: boundingSphereRadius,
                            springDisplacementX: settingsSnapshot.springDisplacement.x,
                            springDisplacementY: settingsSnapshot.springDisplacement.y,
                            springDisplacementZ: settingsSnapshot.springDisplacement.z,
                            springStretch: simd_length(settingsSnapshot.springDisplacement),
                            springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                            springVisible: (settingsSnapshot.springActive || simd_length(settingsSnapshot.springDisplacement) > 0.001) ? 1 : 0,
                            springRestRadius: 0.06,
                            jitterOffset: .zero,
                            renderResolution: [1, 1],
                            floorPlane: floorCircle.plane,
                            floorCenterRadius: floorCircle.centerRadius,
                            formulaParams: settingsSnapshot.formulaParams,
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

        return RendererFramePreparation(
            frameTime: frameTime,
            precomputedFractal: precomputedFractal,
            precomputedLighting: precomputedLighting,
            precomputedAudio: precomputedAudio,
            precomputedFog: precomputedFog,
            modelMatrix: modelMatrix,
            maxViewDistance: maxViewDistance,
            effectiveScale: effectiveScale,
            animatedColorMix: animatedColorMix,
            animatedGlow: animatedGlow,
            perEye: preparedEyeStates
        )
    }
}
