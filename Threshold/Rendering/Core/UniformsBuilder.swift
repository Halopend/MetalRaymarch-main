//  UniformsBuilder.swift
//
//  Single source of truth for assembling the shader-facing `Uniforms` struct
//  (TECH_DEBT.md #2 / audit item H). Historically the ~76-field `Uniforms(...)`
//  initializer was hand-copied at three sites — the visionOS game-state path
//  (`RendererGameState`), the Mac path (`RaymarchRenderView.makeUniforms`), and
//  the Quick Look path (`HeadlessRenderer.packUniforms`). Every new field had to
//  be added in all three in the same order, and the identical derived math
//  (safety-bubble scale correction, march-epsilon / LOD zoom rescale, spring
//  visibility, animated color/glow) was pasted verbatim. That copy-drift bit
//  three times in three days.
//
//  This file collapses the field list AND the shared derived math into one
//  function. The fields that genuinely differ per platform (matrices, the
//  precomputes each caller builds its own way, hand tracking, floor circle,
//  benchmark flags, bounding / bound-to-space / env-scrunch / dist-cache) are
//  named explicitly in `UniformsPlatformInputs`, so adding a `Uniforms` field is
//  now a single compile-checked edit here plus (if platform-specific) one field
//  on the struct — never a silent three-way divergence.
//
//  It references only types available in every target (Uniforms, the Precomputed*
//  blocks, RenderSettingsSnapshot, RenderPrecompute); anything platform-owned
//  (AppModel, BenchmarkManager, EnvironmentSDFGrid, hand tracking) is resolved by
//  the caller and passed in. This file is in the Quick Look SHARED_SOURCES set.

import Foundation
import Metal
import simd

/// Immutable GPU copy of the bundled 3DBenchy signed-distance volume.
///
/// The 64-byte file header is intentionally kept off-GPU; the shader sees only
/// tightly packed Float16 voxels and reaches them through `gpuAddress`.
final class BenchySDFGPUAsset: @unchecked Sendable {
    static let resourceName = "Benchy"
    static let resourceExtension = "sdfbin"
    static let headerSize = 64
    static let expectedVoxelBytes = 96 * 96 * 96 * MemoryLayout<UInt16>.stride

    let buffer: MTLBuffer?

    init(device: MTLDevice, bundle: Bundle = .main) {
        let url = bundle.url(
            forResource: Self.resourceName,
            withExtension: Self.resourceExtension
        ) ?? bundle.url(
            forResource: Self.resourceName,
            withExtension: Self.resourceExtension,
            subdirectory: "Resources"
        )
        guard let url,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count == Self.headerSize + Self.expectedVoxelBytes,
              data.prefix(7) == Data("THRSDF1".utf8)
        else {
            buffer = nil
            return
        }

        let dimension: UInt32 = data.subdata(in: 8..<12).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        guard UInt32(littleEndian: dimension) == UInt32(BENCHY_SDF_DIM) else {
            buffer = nil
            return
        }

        let payload = data.dropFirst(Self.headerSize)
        buffer = payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: payload.count,
                options: .storageModeShared
            )
        }
        buffer?.label = "3DBenchy signed-distance volume"
    }

    var gpuAddress: UInt64 { buffer?.gpuAddress ?? 0 }
}

/// The per-frame, per-platform inputs the shared `Uniforms` assembler cannot
/// derive from `(snapshot, effectiveScale, time)` alone. Each caller computes
/// these with its own matrices, precomputes, and feature availability.
struct UniformsPlatformInputs {
    // Geometry / camera (per eye on visionOS).
    var projectionMatrix: matrix_float4x4      // already jitter-baked where applicable
    var modelViewMatrix: matrix_float4x4
    var inverseModelViewMatrix: matrix_float4x4
    var modelToWorldMatrix: matrix_float4x4    // march/model space → world meters
    var boundSpaceWorldToLocalMatrix: matrix_float4x4 // world meters → centered room meters

    // Temporal warm-start (visionOS fragment path only; identity elsewhere).
    var previousViewProjMatrix: matrix_float4x4
    var previousInvViewProjMatrix: matrix_float4x4

    // Per-platform smoothed / capped horizon.
    var maxViewDistance: Float

    // Cone-marching footprint: needs the platform's projection + viewport height.
    var coneMarchScale: Float
    var pixelFootprintPerDist: Float

    // Safety-bubble radius in METERS, before the shared /effectiveScale correction.
    // visionOS may shrink this for mixed immersion; Mac/QL pass the raw setting.
    var safetyBubbleRadiusMeters: Float

    // Hand Attraction is visionOS-only (ARKit); `.off` on Mac/QL.
    var handField: HandFieldParams

    // Precomputes — each caller builds these its own way (Mac sanitizes audio).
    var precomputedFractal: PrecomputedFractalParams
    var precomputedLighting: PrecomputedLighting
    var precomputedAudio: PrecomputedAudio
    var precomputedFog: PrecomputedFog
    var colorScheme: ColorSchemeParams

    // Floor circle: real on the visionOS game path, default plane elsewhere.
    var floorPlane: SIMD4<Float>
    var floorCenterRadius: SIMD4<Float>

    // Warm-start UV resolution: [1,1] on the interactive paths, real size on QL.
    var renderResolution: SIMD2<Float>

    // Benchmark-only selectors (0 in normal use; differ by harness per platform).
    var benchCollectSteps: Int32
    var benchAblate: UInt32

    // Partial-immersion passthrough (visionOS only; 0 elsewhere).
    var passthroughBackground: Int32

    // Bounding Shape edge treatment.
    var boundingFogEnabled: Int32
    var boundingShadowDepth: Float
    var boundingShapeType: Float
    var boundingShapeCenter: SIMD3<Float>

    // Bound to Space (assumed-room clip): live-room feature; off for thumbnails.
    var boundToSpaceMode: Int32
    var boundSpaceSize: SIMD3<Float>
    var boundAmbientStrength: Float

    // Scanned-environment scrunch + fractal distance cache (bindless grids).
    var envScrunch: EnvScrunchParams
    var distCache: DistanceCacheParams
    var benchySDFAddress: UInt64
}

func packedSceneFields(
    base: EnvScrunchParams,
    primitives: [ScenePrimitive],
    benchySDFAddress: UInt64
) -> EnvScrunchParams {
    var result = base
    result.benchySDFAddress = benchySDFAddress

    let active = Array(primitives.prefix(Int(kMaxScenePrimitives)))
    withUnsafeMutablePointer(to: &result.scenePrimitives) { tuplePointer in
        tuplePointer.withMemoryRebound(
            to: ScenePrimitiveGPU.self,
            capacity: Int(kMaxScenePrimitives)
        ) { records in
            for (index, primitive) in active.enumerated() {
                let position = SIMD3<Float>(
                    primitive.position.x.isFinite ? primitive.position.x : 0,
                    primitive.position.y.isFinite ? primitive.position.y : 0,
                    primitive.position.z.isFinite ? primitive.position.z : 0
                )
                let scale = primitive.scale.isFinite
                    ? min(max(primitive.scale, 0.01), 30)
                    : 1
                let dimensions = simd_clamp(
                    SIMD3<Float>(
                        primitive.dimensions.x.isFinite ? primitive.dimensions.x : 1,
                        primitive.dimensions.y.isFinite ? primitive.dimensions.y : 1,
                        primitive.dimensions.z.isFinite ? primitive.dimensions.z : 1
                    ),
                    SIMD3<Float>(repeating: 0.001),
                    SIMD3<Float>(repeating: 30)
                )
                records[index] = ScenePrimitiveGPU(
                    positionScale: SIMD4<Float>(position, scale),
                    dimensionsKind: SIMD4<Float>(
                        dimensions,
                        Float(primitive.kind.gpuSelector)
                    )
                )
            }
        }
    }
    result.scenePrimitiveCount = Int32(active.count)
    return result
}

/// Manual/fallback Bound to Space transform. Authored dimensions retain their
/// historical placement: footprint centered on world X/Z with the floor at
/// world Y=0. Automatic room sensing replaces this transform on Vision Pro.
func manualBoundSpaceWorldToLocalMatrix(size: SIMD3<Float>) -> matrix_float4x4 {
    var result = matrix_identity_float4x4
    result.columns.3.y = -max(size.y, 0.01) * 0.5
    return result
}

/// Assemble the shader-facing `Uniforms` from the frame snapshot, the resolved
/// zoom `effectiveScale`, the frame `time`, and the platform-specific inputs.
///
/// All fields that are a pure function of `(settings, effectiveScale, time)` are
/// computed here — including the derived math that used to be pasted at all three
/// sites — so they can never silently diverge again.
func assembleUniforms(settings: RenderSettingsSnapshot,
                      effectiveScale: Float,
                      time: Float,
                      platform: UniformsPlatformInputs) -> Uniforms {
    // ── Shared derived math (was duplicated verbatim at all three call sites) ──

    // Infinite-zoom epsilon / LOD rescale — both 1.0 at scale >= 0.15 so they are
    // byte-identical there; loosen past the zoom-out floor.
    let zoomOutEpsilonLoosen: Float = max(1.0, 0.15 / max(effectiveScale, 1e-4))
    let zoomOutLODScale: Float = min(1.0, effectiveScale / 0.15)
    let marchEpsilonScale: Float = (1.0 / max(effectiveScale, 1.0)) * zoomOutEpsilonLoosen
    let distanceLODFalloff: Float = settings.distanceLODStrength * 0.5 * zoomOutLODScale

    // Scale-relative safety bubble: keep radius/fade constant in world space.
    let scaleCorrectedBubbleRadius = platform.safetyBubbleRadiusMeters / max(effectiveScale, 0.001)
    let scaleCorrectedFadeWidth = settings.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

    let isMandelbulb = settings.fractalType == .mandelbulb
    let safetyBubbleEnabled: Int32 = isMandelbulb ? 0 : (settings.safetyBubbleEnabled ? 1 : 0)
    let safetyBubbleStrength: Float = isMandelbulb ? 0.0 : settings.safetyBubbleStrength

    let sphereProjectionBlend: Float = settings.sphereProjectionEnabled ? settings.sphereProjectionBlend : 0

    // Lighting-play animation (identical formula everywhere).
    let lightingWave = sin(time * 1.2)
    let baseColorMix = settings.colorMix
    let baseGlow = settings.colorSchemeParams.glowIntensity
    let animatedColorMix = settings.lightingPlay ? min(max(baseColorMix + lightingWave * 0.08, 0.0), 1.0) : baseColorMix
    let animatedGlow = settings.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow

    // Spring blob navigation widget.
    let springLen = simd_length(settings.springDisplacement)
    let springVisible: Int32 = (settings.springActive || springLen > 0.001) ? 1 : 0
    let envAndSceneFields = packedSceneFields(
        base: platform.envScrunch,
        primitives: settings.scenePrimitives,
        benchySDFAddress: platform.benchySDFAddress
    )

    return Uniforms(projectionMatrix: platform.projectionMatrix,
                    modelViewMatrix: platform.modelViewMatrix,
                    inverseModelViewMatrix: platform.inverseModelViewMatrix,
                    previousViewProjMatrix: platform.previousViewProjMatrix,
                    previousInvViewProjMatrix: platform.previousInvViewProjMatrix,
                    time: time,
                    minDistance: settings.minDistance,
                    fractalScale: settings.fractalScale,
                    fractalIterations: Int32(settings.fractalIterations),
                    maxRaySteps: Int32(settings.maxRaySteps),
                    maxViewDistance: platform.maxViewDistance,
                    marchEpsilonScale: marchEpsilonScale,
                    colorMix: animatedColorMix,
                    glowIntensity: animatedGlow,
                    foldingLimit: settings.foldingLimit,
                    sphereRadius: settings.sphereRadius,
                    safetyBubbleRadius: scaleCorrectedBubbleRadius,
                    safetyBubbleEnabled: safetyBubbleEnabled,
                    safetyBubbleShape: settings.safetyBubbleShape,
                    safetyBubbleFadeEnabled: settings.safetyBubbleFadeEnabled ? 1 : 0,
                    safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                    safetyBubbleStrength: safetyBubbleStrength,
                    handField: platform.handField,
                    colorIterations: settings.colorIterations,
                    limitFlash: settings.limitFlash,
                    activeGesture: Int32(settings.activeGestureIndex),
                    warmStartEnabled: 0,
                    fractalType: settings.fractalType.rawValue,
                    lightingSoftness: settings.lightingSoftness,
                    sphericalInversionMode: settings.sphericalInversionMode.rawValue,
                    sphericalInversionRadius: settings.sphericalInversionRadius,
                    sphereProjectionBlend: sphereProjectionBlend,
                    sphereProjectionRadius: settings.sphereProjectionRadius,
                    spaceWarpStrength: settings.spaceWarpStrength,
                    spaceWarpParam1: settings.spaceWarpParam1,
                    spaceWarpParam2: settings.spaceWarpParam2,
                    spaceWarpParam3: settings.spaceWarpParam3,
                    spaceWarpAxis: settings.spaceWarpAxis,
                    spaceWarpStack: settings.spaceWarpStack,
                    stepMultiplier: settings.stepMultiplier,
                    boundingSphereRadius: settings.estimatedBoundingSphereRadius,
                    smartAdvanceEnabled: settings.smartAdvanceEnabled ? 1 : 0,
                    coneMarchScale: platform.coneMarchScale,
                    coneCoverageAAEnabled: settings.coneCoverageAAEnabled ? 1 : 0,
                    shadowsEnabled: settings.shadowsEnabled ? 1 : 0,
                    distanceLODFalloff: distanceLODFalloff,
                    benchCollectSteps: platform.benchCollectSteps,
                    pixelFootprintPerDist: platform.pixelFootprintPerDist,
                    coarseRateMagMax: 1.0,
                    springDisplacementX: settings.springDisplacement.x,
                    springDisplacementY: settings.springDisplacement.y,
                    springDisplacementZ: settings.springDisplacement.z,
                    springStretch: springLen,
                    springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                    springVisible: springVisible,
                    springRestRadius: 0.06,
                    jitterOffset: .zero,
                    renderResolution: platform.renderResolution,
                    floorPlane: platform.floorPlane,
                    floorCenterRadius: platform.floorCenterRadius,
                    formulaParams: settings.formulaParams,
                    precomputedFractal: platform.precomputedFractal,
                    precomputedLighting: platform.precomputedLighting,
                    precomputedAudio: platform.precomputedAudio,
                    precomputedFog: platform.precomputedFog,
                    colorScheme: platform.colorScheme,
                    benchAblate: platform.benchAblate,
                    passthroughBackground: platform.passthroughBackground,
                    boundingFogEnabled: platform.boundingFogEnabled,
                    boundingShadowDepth: platform.boundingShadowDepth,
                    boundingShapeType: platform.boundingShapeType,
                    boundToSpaceMode: platform.boundToSpaceMode,
                    boundSpaceSize: platform.boundSpaceSize,
                    boundAmbientStrength: platform.boundAmbientStrength,
                    modelToBoundSpaceMatrix: platform.boundSpaceWorldToLocalMatrix * platform.modelToWorldMatrix,
                    envScrunch: envAndSceneFields,
                    distCache: platform.distCache,
                    boundingShapeCenter: platform.boundingShapeCenter)
}
