//
//  IOSViewportRenderConfiguration.swift
//  Threshold
//
//  The iPhone and iPad hosts deliberately share one Metal surface contract.
//  Keep the device class explicit at this boundary so the parity is testable
//  from the macOS unit-test target without starting a UIKit application.
//

@preconcurrency import Metal

enum IOSViewportDevice: CaseIterable, Sendable {
    case iPhone
    case iPad
}

struct IOSViewportRenderConfiguration: Equatable, Sendable {
    let colorPixelFormat: MTLPixelFormat
    let depthStencilPixelFormat: MTLPixelFormat
    let clearRed: Double
    let clearGreen: Double
    let clearBlue: Double
    let clearAlpha: Double
    let clearDepth: Double
    let framebufferOnly: Bool
    let automaticallyResizesDrawable: Bool

    var clearColor: MTLClearColor {
        MTLClearColor(
            red: clearRed,
            green: clearGreen,
            blue: clearBlue,
            alpha: clearAlpha
        )
    }

    /// Rendering is intentionally device-agnostic: device class may change
    /// interaction chrome and frame pacing, but never the Metal surface.
    static func rendering(for device: IOSViewportDevice) -> Self {
        shared
    }

    private static let shared = Self(
        colorPixelFormat: .rgba16Float,
        depthStencilPixelFormat: .depth32Float,
        clearRed: 0.005,
        clearGreen: 0.006,
        clearBlue: 0.008,
        clearAlpha: 1.0,
        clearDepth: 1.0,
        framebufferOnly: true,
        automaticallyResizesDrawable: true
    )
}
