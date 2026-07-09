@preconcurrency import CompositorServices
import Foundation
import QuartzCore
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
    var handAttraction: HandAttractionUniforms
    var envScrunch: EnvScrunchParams
}

/// Hand Attraction (visionOS only): per-hand interaction sphere state, already
/// converted to MODEL space and scale-corrected — ready to drop straight into
/// either the fragment (Uniforms) or compute (TileUniforms) uniform builders.
struct HandAttractionUniforms {
    var enabled: Int32 = 0
    var radius: Float = 0
    var strength: Float = 0
    var pocketEnabled: Int32 = 0
    // x = ball size (×radius), y = blend softness, z = pocket size (×ball), w = pocket softness
    var shape: SIMD4<Float> = HandFieldParams.defaultShape
    var leftPosition: SIMD3<Float> = .zero
    var leftActive: Int32 = 0
    var rightPosition: SIMD3<Float> = .zero
    var rightActive: Int32 = 0
    // Forearm capsules (model space): A = wrist (w: 1 tracked / 0),
    // B = elbow (w: capsule radius, model units; 0 = forearms off).
    var leftForearmA: SIMD4<Float> = .zero
    var leftForearmB: SIMD4<Float> = .zero
    var rightForearmA: SIMD4<Float> = .zero
    var rightForearmB: SIMD4<Float> = .zero

    /// Shader-facing packed form (TECH_DEBT.md #8d): the block Uniforms /
    /// TileUniforms carry once, pointed at by FractalParams. Active flags
    /// ride the position .w lanes (1 = tracked / 0).
    var asHandFieldParams: HandFieldParams {
        var p = HandFieldParams()
        p.enabled = enabled
        p.radius = radius
        p.strength = strength
        p.pocketEnabled = pocketEnabled
        p.shape = shape
        p.leftHand = SIMD4<Float>(leftPosition, leftActive != 0 ? 1.0 : 0.0)
        p.rightHand = SIMD4<Float>(rightPosition, rightActive != 0 ? 1.0 : 0.0)
        p.leftForearmA = leftForearmA
        p.leftForearmB = leftForearmB
        p.rightForearmA = rightForearmA
        p.rightForearmB = rightForearmB
        return p
    }
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

        guard platformRadius > 0 else {
            // Disabled: zero radius makes evaluateFloorCircle bail immediately.
            return (SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 0, 0))
        }
        let floorRadiusMeters = max(0.5, platformRadius)
        let floorRadiusModel = floorRadiusMeters / max(effectiveScale, 0.001)
        let floorCenterRadius = SIMD4<Float>(floorCenterModel.x, floorCenterModel.y, floorCenterModel.z, floorRadiusModel)

        return (floorPlane, floorCenterRadius)
    }

    /// Transforms a world-space point into the MODEL space the raymarcher runs
    /// in (same math as the floor-circle center above, factored out for reuse).
    private static func worldToModel(_ worldPoint: SIMD3<Float>, inverseModelMatrix: matrix_float4x4) -> SIMD3<Float> {
        let homogeneous = inverseModelMatrix * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        let w = abs(homogeneous.w) > 1e-6 ? homogeneous.w : 1.0
        return SIMD3<Float>(homogeneous.x, homogeneous.y, homogeneous.z) / w
    }

    /// Hand Attraction (visionOS only): converts each tracked palm's world-space
    /// position into the MODEL-space point the shader's interaction sphere uses,
    /// and scale-corrects the radius so it reads as a constant real-world size
    /// regardless of the fractal's current detail zoom (mirrors the safety bubble).
    private func makeHandAttractionUniforms(
        settingsSnapshot: RenderSettingsSnapshot,
        modelMatrix: matrix_float4x4,
        effectiveScale: Float,
        deviceTransform: matrix_float4x4
    ) -> HandAttractionUniforms {
        var state = HandAttractionUniforms()
        guard settingsSnapshot.handAttractionEnabled else { return state }
        guard lastLeftHandTrackedForAttraction || lastRightHandTrackedForAttraction else { return state }

        let inverseModelMatrix = modelMatrix.inverse
        state.enabled = 1
        state.radius = settingsSnapshot.handAttractionRadius / max(effectiveScale, 0.001)
        state.strength = settingsSnapshot.handAttractionStrength
        state.pocketEnabled = settingsSnapshot.handAttractionPocketEnabled ? 1 : 0
        state.shape = SIMD4<Float>(settingsSnapshot.handAttractionBallScale,
                                   settingsSnapshot.handAttractionSoftness,
                                   settingsSnapshot.handAttractionPocketSize,
                                   settingsSnapshot.handAttractionPocketSoftness)

        // Reach offset: project the ball outward along the body-center→hand
        // direction, in WORLD space (meters), so the ball floats in front of
        // the palm instead of sitting on it. Body center ≈ head dropped to
        // chest height, so reaching up/down/sideways all project outward.
        let headWorld = SIMD3<Float>(deviceTransform.columns.3.x,
                                     deviceTransform.columns.3.y,
                                     deviceTransform.columns.3.z)
        let bodyCenterWorld = headWorld - SIMD3<Float>(0, 0.25, 0)
        let reach = settingsSnapshot.handAttractionProjectionDistance
        func projected(_ handWorld: SIMD3<Float>) -> SIMD3<Float> {
            guard reach > 0.001 else { return handWorld }
            let offset = handWorld - bodyCenterWorld
            let length = simd_length(offset)
            guard length > 1e-4 else { return handWorld }
            return handWorld + (offset / length) * reach
        }

        if lastLeftHandTrackedForAttraction {
            state.leftPosition = Self.worldToModel(projected(lastLeftHandPalmPosition), inverseModelMatrix: inverseModelMatrix)
            state.leftActive = 1
        }
        if lastRightHandTrackedForAttraction {
            state.rightPosition = Self.worldToModel(projected(lastRightHandPalmPosition), inverseModelMatrix: inverseModelMatrix)
            state.rightActive = 1
        }

        // Forearm capsules: anchored at the REAL wrist/elbow (never reach-
        // projected — the arm is where the arm is). Radius scale-corrected
        // like the ball so it reads as a constant real-world thickness.
        if settingsSnapshot.handAttractionForearmEnabled {
            let forearmRadiusModel = settingsSnapshot.handAttractionForearmRadius / max(effectiveScale, 0.001)
            if lastLeftForearmTracked {
                let a = Self.worldToModel(lastLeftForearmWrist, inverseModelMatrix: inverseModelMatrix)
                let b = Self.worldToModel(lastLeftForearmElbow, inverseModelMatrix: inverseModelMatrix)
                state.leftForearmA = SIMD4<Float>(a, 1)
                state.leftForearmB = SIMD4<Float>(b, forearmRadiusModel)
            }
            if lastRightForearmTracked {
                let a = Self.worldToModel(lastRightForearmWrist, inverseModelMatrix: inverseModelMatrix)
                let b = Self.worldToModel(lastRightForearmElbow, inverseModelMatrix: inverseModelMatrix)
                state.rightForearmA = SIMD4<Float>(a, 1)
                state.rightForearmB = SIMD4<Float>(b, forearmRadiusModel)
            }
        }
        return state
    }

    func updateGameState(drawable: LayerRenderer.Drawable, settingsSnapshot: RenderSettingsSnapshot) -> RendererFramePreparation {
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
        let isKleinianFamily =
            settingsSnapshot.fractalType == .kleinian ||
            settingsSnapshot.fractalType == .theliPseudoKleinian

        // Kleinian formulas benefit from a larger trace horizon when zooming out;
        // otherwise they look artificially bounded and fade away too early.
        let traceScaleFloor: Float = isKleinianFamily ? 0.02 : 0.15
        let traceScale = max(effectiveScale, traceScaleFloor)
        // Family cap + base horizon stay below the projection far plane (farZ 500)
        // so raymarch depth stays valid for compositing. (The old render-distance
        // multiplier was measured to have almost no perf effect; hardcoded to 1×.)
        let maxViewDistanceCap: Float = isKleinianFamily ? 420.0 : 80.0
        let baseViewDistance: Float = isKleinianFamily
            ? (RenderSettings.maxViewDistance * 2.0)
            : RenderSettings.maxViewDistance
        var targetMaxViewDistance = min(maxViewDistanceCap, baseViewDistance / traceScale)
        // Zoom-out: once traceScale floors, the WORLD horizon (maxViewDistance ×
        // scale) shrinks with the model and the fractal dissolves at a
        // camera-centered sphere. Lift the horizon so the world-space range never
        // drops below baseViewDistance. No-op while effectiveScale >= the floor.
        // Use raw device anchor transform (no smoothing) to ensure compositor-predicted pose is used
        let deviceTransform = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let safeScale = max(effectiveScale, 1e-4)
        if effectiveScale < traceScaleFloor {
            // Cover camera→model distance too (position offsets eat into the
            // budget), and stay under kRayMissThreshold (900) — hits past it are
            // classified as misses in the shader.
            let devicePos = SIMD3<Float>(deviceTransform.columns.3.x,
                                         deviceTransform.columns.3.y,
                                         deviceTransform.columns.3.z)
            let camDistWorld = simd_length(devicePos - smoothedPosition)
            targetMaxViewDistance = max(targetMaxViewDistance,
                                        min(880.0, (camDistWorld + baseViewDistance) / safeScale))
        }
        let maxViewDistanceSpeed: Float = (targetMaxViewDistance > smoothedMaxViewDistance) ? 30.0 : 10.0
        let maxViewDistanceBlend = 1.0 - exp(-maxViewDistanceSpeed * cachedDeltaTime)
        smoothedMaxViewDistance += (targetMaxViewDistance - smoothedMaxViewDistance) * maxViewDistanceBlend
        let horizonCap = max(maxViewDistanceCap, 880.0)
        let maxViewDistance = max(4.0, min(horizonCap, smoothedMaxViewDistance))
        let scaleMatrix = matrix4x4_scale(effectiveScale, effectiveScale, effectiveScale)

        let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix
        // Glass-floor platform: honor the user toggle, and force it off in
        // Mixed immersion — the real floor is visible there, so a virtual
        // platform floating over passthrough is just clutter. Radius <= 0
        // disables the circle in makeFloorCircleUniforms/the shader.
        let platformVisible = settingsSnapshot.platformEnabled
            && appModel.immersionStyleForRenderer != .mixed
        let floorCircle = Self.makeFloorCircleUniforms(
            modelMatrix: modelMatrix,
            effectiveScale: effectiveScale,
            deviceTransform: deviceTransform,
            platformRadius: platformVisible ? settingsSnapshot.platformRadius : 0
        )
        let handAttraction = makeHandAttractionUniforms(
            settingsSnapshot: settingsSnapshot,
            modelMatrix: modelMatrix,
            effectiveScale: effectiveScale,
            deviceTransform: deviceTransform
        )
        let envScrunchParams = makeEnvScrunchParams(
            settingsSnapshot: settingsSnapshot,
            modelMatrix: modelMatrix
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
        // Live elapsed-time clock (replaces the removed frozen AppClock) so the
        // visionOS path animates ambient time-motion — dither, spring vibration,
        // light-orbit drift — matching the Mac/iOS path (RaymarchRenderView).
        let frameTime = Float(CACurrentMediaTime() - renderStartTime)
        let precomputedFractal = RenderPrecompute.makePrecomputedFractal(from: settingsSnapshot)
        let precomputedLighting = RenderPrecompute.makePrecomputedLighting(
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
        let precomputedAudio = RenderPrecompute.makePrecomputedAudio(from: settingsSnapshot)
        var precomputedFog = RenderPrecompute.makePrecomputedFog(from: settingsSnapshot)
        // Zoom fog compensation (Settings toggle, default off): fog operates on
        // MODEL-space march distance, so on zoom-out the fog sphere's world radius
        // shrinks with the model and washes out the fractal — starting as soon as
        // scale drops below 1.0. Scaling intensity by effectiveScale holds the
        // fog's WORLD radius constant at its scale==1 value for the whole
        // zoom-out range — a no-op at scale >= 1 (zoom-in unaffected). (Was
        // previously hardcoded on for the Kleinian family only, and briefly keyed
        // to the unrelated 0.15 horizon-lift floor.)
        precomputedFog = RenderPrecompute.applyZoomFogCompensation(
            precomputedFog,
            enabled: settingsSnapshot.zoomFogCompensationEnabled,
            effectiveScale: effectiveScale)

        // Hoist lightingWave out of per-eye loop — sin() is identical for both eyes
        let baseColorMix = settingsSnapshot.colorMix
        let baseGlow = settingsSnapshot.colorSchemeParams.glowIntensity
        let lightingWave = sin(frameTime * 1.2)
        let animatedColorMix = settingsSnapshot.lightingPlay ? min(max(baseColorMix + lightingWave * 0.08, 0.0), 1.0) : baseColorMix
        let animatedGlow = settingsSnapshot.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow

        let boundingSphereRadius = settingsSnapshot.estimatedBoundingSphereRadius
        // Zoom-out epsilon/LOD rescale (both 1.0 at scale >= 0.15 → byte-identical):
        // the hit threshold must loosen ∝ 1/scale to track the constant world-space
        // pixel footprint (this also bounds step cost over the lifted horizon), and
        // distance-LOD reads model-space t, so its falloff shrinks with scale to
        // avoid collapsing iterations everywhere on zoom-out.
        let zoomOutEpsilonLoosen: Float = max(1.0, 0.15 / max(effectiveScale, 1e-4))
        let zoomOutLODScale: Float = min(1.0, effectiveScale / 0.15)
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
            // Mixed immersion: cap the comfort bubble to the mixed radius —
            // you're "outside" the fractal there, a big bubble just hollows it.
            let bubbleRadiusMeters = (appModel.immersionStyleForRenderer == .mixed && settingsSnapshot.safetyBubbleMixedAutoShrink)
                ? min(settingsSnapshot.safetyBubbleRadius, settingsSnapshot.safetyBubbleMixedRadius)
                : settingsSnapshot.safetyBubbleRadius
            let scaleCorrectedBubbleRadius = bubbleRadiusMeters / max(effectiveScale, 0.001)
            let scaleCorrectedFadeWidth = settingsSnapshot.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

            // Previous frame's view-proj (model → prev clip) for the temporal
            // depth warm-start. updateGameState runs before finishFragmentPass
            // rotates these, so they still hold last frame's matrices here.
            let prevViewProj = viewIndex < previousViewProjMatrices.count
                ? previousViewProjMatrices[viewIndex]
                : matrix_identity_float4x4

            // Break up the large Uniforms initializer to help the type-checker
            let marchEpsilonScale: Float = (1.0 / max(effectiveScale, 1.0)) * zoomOutEpsilonLoosen
            let safetyBubbleEnabled: Int32 = (settingsSnapshot.fractalType == .mandelbulb) ? 0 : (settingsSnapshot.safetyBubbleEnabled ? 1 : 0)
            let safetyBubbleFadeEnabled: Int32 = settingsSnapshot.safetyBubbleFadeEnabled ? 1 : 0
            let safetyBubbleStrength: Float = (settingsSnapshot.fractalType == .mandelbulb) ? 0.0 : settingsSnapshot.safetyBubbleStrength
            let sphereProjectionBlend: Float = settingsSnapshot.sphereProjectionEnabled ? settingsSnapshot.sphereProjectionBlend : 0
            let smartAdvanceEnabled: Int32 = settingsSnapshot.smartAdvanceEnabled ? 1 : 0
            let coneCoverageAAEnabled: Int32 = settingsSnapshot.coneCoverageAAEnabled ? 1 : 0
            let shadowsEnabled: Int32 = settingsSnapshot.shadowsEnabled ? 1 : 0
            let distanceLODFalloff: Float = settingsSnapshot.distanceLODStrength * 0.5 * zoomOutLODScale
            let benchCollectSteps: Int32 = BenchmarkManager.shared.collectIterations ? 1 : 0
            let viewportHeight: Float = Float(view.textureMap.viewport.height)
            let coneMarchScale: Float = RenderPrecompute.coneMarchScale(strength: settingsSnapshot.coneMarchStrength, projection: projection, viewportHeight: viewportHeight)
            let pixelFootprintPerDist: Float = RenderPrecompute.pixelFootprintPerDist(projection: projection, viewportHeight: viewportHeight)
            let springStretch: Float = simd_length(settingsSnapshot.springDisplacement)
            let springVisible: Int32 = (settingsSnapshot.springActive || springStretch > 0.001) ? 1 : 0
            let passthroughBackground: Int32 = passthroughBackgroundActive ? 1 : 0

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
                            marchEpsilonScale: marchEpsilonScale,
                            colorMix: animatedColorMix,
                            glowIntensity: animatedGlow,
                            foldingLimit: settingsSnapshot.foldingLimit,
                            sphereRadius: settingsSnapshot.sphereRadius,
                            safetyBubbleRadius: scaleCorrectedBubbleRadius,
                            safetyBubbleEnabled: safetyBubbleEnabled,
                            safetyBubbleShape: settingsSnapshot.safetyBubbleShape,
                            safetyBubbleFadeEnabled: safetyBubbleFadeEnabled,
                            safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                            safetyBubbleStrength: safetyBubbleStrength,
                            handField: handAttraction.asHandFieldParams,
                            colorIterations: settingsSnapshot.colorIterations,
                            limitFlash: settingsSnapshot.limitFlash,
                            activeGesture: Int32(settingsSnapshot.activeGestureIndex),
                            warmStartEnabled: 0,
                            fractalType: settingsSnapshot.fractalType.rawValue,
                            lightingSoftness: settingsSnapshot.lightingSoftness,
                            sphericalInversionMode: settingsSnapshot.sphericalInversionMode.rawValue,
                            sphericalInversionRadius: settingsSnapshot.sphericalInversionRadius,
                            sphereProjectionBlend: sphereProjectionBlend,
                            sphereProjectionRadius: settingsSnapshot.sphereProjectionRadius,
                            spaceWarpStrength: settingsSnapshot.spaceWarpStrength,
                            spaceWarpParam1: settingsSnapshot.spaceWarpParam1,
                            spaceWarpParam2: settingsSnapshot.spaceWarpParam2,
                            spaceWarpParam3: settingsSnapshot.spaceWarpParam3,
                            spaceWarpAxis: settingsSnapshot.spaceWarpAxis,
                            spaceWarpStack: settingsSnapshot.spaceWarpStack,
                            stepMultiplier: settingsSnapshot.stepMultiplier,
                            boundingSphereRadius: boundingSphereRadius,
                            smartAdvanceEnabled: smartAdvanceEnabled,
                            coneMarchScale: coneMarchScale,
                            coneCoverageAAEnabled: coneCoverageAAEnabled,
                            shadowsEnabled: shadowsEnabled,
                            distanceLODFalloff: distanceLODFalloff,
                            benchCollectSteps: benchCollectSteps,
                            pixelFootprintPerDist: pixelFootprintPerDist,
                            coarseRateMagMax: 1.0,
                            springDisplacementX: settingsSnapshot.springDisplacement.x,
                            springDisplacementY: settingsSnapshot.springDisplacement.y,
                            springDisplacementZ: settingsSnapshot.springDisplacement.z,
                            springStretch: springStretch,
                            springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                            springVisible: springVisible,
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
                            colorScheme: colorSchemeParams,
                            benchAblate: 0,
                            passthroughBackground: passthroughBackground,
                            boundingFogEnabled: Int32(settingsSnapshot.boundingShapeFogMode),
                            boundingShadowDepth: settingsSnapshot.boundingShapeShadowDepth,
                            boundingShapeType: settingsSnapshot.boundingShapeType,
                            boundToSpaceMode: settingsSnapshot.resolvedBoundToSpaceMode,
                            boundSpaceSize: settingsSnapshot.boundSpaceSize,
                            boundAmbientStrength: settingsSnapshot.boundAmbientStrength,
                            modelToWorldMatrix: modelMatrix,
                            envScrunch: envScrunchParams,
                            // Fractal distance cache is a Mac fragment-path prototype;
                            // inert (disabled) on the visionOS fragment path.
                            distCache: DistanceCacheParams(),
                            // Pin the Bounding Shape while the Linear Rail slides
                            // content through it (0 when the rail is off).
                            boundingShapeCenter: settingsSnapshot.boundingShapeCenterModel(modelMatrix: modelMatrix))
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
            perEye: preparedEyeStates,
            handAttraction: handAttraction,
            envScrunch: envScrunchParams
        )
    }

    /// Environment Scrunch: fuse the latest published environment-SDF grid
    /// (scene-reconstruction bake) with this frame's model matrix and the
    /// user's knobs. Default (enabled 0) whenever the feature is off or no
    /// bake has been published yet.
    private func makeEnvScrunchParams(
        settingsSnapshot: RenderSettingsSnapshot,
        modelMatrix: matrix_float4x4
    ) -> EnvScrunchParams {
        guard settingsSnapshot.envScrunchEnabled,
              let grid = environmentSDF.withLock({ $0 }) else { return EnvScrunchParams() }
        return settingsSnapshot.makeEnvScrunchParams(
            modelToWorld: modelMatrix,
            gridOrigin: grid.originWorld,
            gridCell: grid.cellSize,
            gridAddress: grid.gpuAddress,
            surfaceMinWorld: grid.surfaceMinWorld,
            surfaceMaxWorld: grid.surfaceMaxWorld,
            farClampMeters: EnvironmentSDFGrid.clampFar)
    }
}
