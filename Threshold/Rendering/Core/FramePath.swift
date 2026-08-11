//
//  FramePath.swift
//  Threshold
//
//  Render-path selection value types: which path a frame takes (compute vs
//  fragment), the fragment pass plan, the optional MetalFX upscale bundle, and
//  the per-frame phase-timing breakdown. Extracted from RendererRenderSupport.swift
//  to give these types a focused home; the selection logic (Renderer.selectFramePath)
//  stays with the Renderer extension. Pure relocation — no behavior change.
//

import Foundation
import Metal

enum RenderFramePath: Equatable {
    case adaptiveCompute
    case fragment
}

#if canImport(MetalFX)
struct RendererMetalFXBundle {
    let manager: MetalFXManager
    let inputWidth: Int
    let inputHeight: Int
}
#endif

struct RendererFragmentPassPlan {
    let renderPassDescriptor: MTLRenderPassDescriptor
    let viewports: [MTLViewport]
    let resolutionScale: Float
#if canImport(MetalFX)
    let metalFXBundle: RendererMetalFXBundle?
    /// True only when the full-resolution resolve path is available, so the
    /// low-resolution raymarch may safely bind an empty output-filter stack.
    let defersPostFilters: Bool
#endif
}

struct FramePhaseBreakdown {
    var backgroundCpuMs: Double = 0
    var clockWaitMs: Double = 0
    var inFlightWaitMs: Double = 0
    var handTrackingMs: Double = 0
    var settingsUpdateMs: Double = 0
    var snapshotMs: Double = 0
    var updateGameStateMs: Double = 0
    var renderPathEncodeMs: Double = 0

    static let zero = FramePhaseBreakdown()
}
