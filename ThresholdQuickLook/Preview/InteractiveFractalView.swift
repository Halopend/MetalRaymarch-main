import Cocoa
import MetalKit
import simd

/// A live, draggable fractal view for the Quick Look preview.
///
/// Holds the scene's `RenderSettings` and re-renders on demand as the user
/// interacts:
///   * drag  → orbit (yaw/pitch applied on top of the scene's authored rotation)
///   * scroll → zoom (model scale, matching the app's desktop zoom semantics)
///
/// Rendering is on-demand (`isPaused` + `enableSetNeedsDisplay`) so an idle
/// preview costs nothing.
final class InteractiveFractalView: MTKView {

    private let settings: RenderSettings
    private let formula: EmbeddedFormula?
    private let baseRotation: simd_quatf
    private let baseScale: Float

    private var yaw: Float = 0     // radians, accumulated from horizontal drag
    private var pitch: Float = 0   // radians, accumulated from vertical drag
    private var zoom: Float = 1     // multiplies the scene's base scale

    private let orbitSensitivity: Float = 0.008
    private let zoomSensitivity: Float = 0.02

    init?(settings: RenderSettings, formula: EmbeddedFormula?) {
        guard let device = HeadlessRenderer.shared?.metalDevice else { return nil }
        self.settings = settings
        self.formula = formula
        self.baseRotation = settings.worldRotation
        self.baseScale = settings.scale
        super.init(frame: .zero, device: device)

        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Interaction

    override func mouseDragged(with event: NSEvent) {
        yaw += Float(event.deltaX) * orbitSensitivity
        pitch += Float(event.deltaY) * orbitSensitivity
        applyCamera()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // Scroll up (positive) zooms in.
        zoom *= (1 + Float(event.scrollingDeltaY) * zoomSensitivity)
        zoom = min(max(zoom, 0.15), 12.0)
        applyCamera()
        needsDisplay = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        // Right-drag also orbits (convenience).
        mouseDragged(with: event)
    }

    private func applyCamera() {
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let qPitch = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        settings.worldRotation = simd_normalize(qYaw * qPitch * baseRotation)
        settings.scale = baseScale * zoom
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        HeadlessRenderer.shared?.render(snapshot: settings.snapshot(), in: self, formula: formula)
    }
}
