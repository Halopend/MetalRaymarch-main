#if os(macOS) || os(iOS)
import Metal
@preconcurrency import MetalKit
import ModelIO
import QuartzCore
import Synchronization
import SwiftUI
import simd
#if os(macOS)
import AppKit
#endif

enum ThresholdMacMovementKey: Hashable, Sendable {
    case forward
    case backward
    case left
    case right
}

private struct ThresholdMacInputFrame: Sendable {
    var pressedKeys: Set<ThresholdMacMovementKey> = []
    var isShiftPressed: Bool = false
    var orbitDelta: SIMD2<Float> = .zero
    var panDelta: SIMD2<Float> = .zero
    var zoomDelta: Float = 0
    var shouldTogglePlayback = false
    var shouldResetView = false
    // Net scene-switch steps requested this frame (left/right arrow keys).
    // Positive = advance, negative = go back.
    var sceneStep = 0
}

#if os(macOS)
private protocol ThresholdMacViewportInputDelegate: AnyObject {
    func viewportDidChangeFocus(_ isFocused: Bool)
    func viewportDidOrbit(delta: SIMD2<Float>)
    func viewportDidPan(delta: SIMD2<Float>)
    func viewportDidZoom(delta: Float)
    func viewportDidChangeKey(_ key: ThresholdMacMovementKey, isPressed: Bool)
    func viewportDidChangeShift(_ isPressed: Bool)
    func viewportDidTogglePlayback()
    func viewportDidRequestReset()
    func viewportDidRequestSceneStep(_ step: Int)
}
#endif

private final class ThresholdMacInputController: Sendable {
    private struct State {
        var pressedKeys: Set<ThresholdMacMovementKey> = []
        var isShiftPressed: Bool = false
        var orbitDelta: SIMD2<Float> = .zero
        var panDelta: SIMD2<Float> = .zero
        var zoomDelta: Float = 0
        var shouldTogglePlayback = false
        var shouldResetView = false
        var sceneStep = 0
    }

    private let state = Mutex(State())

    func setFocus(_ isFocused: Bool) {
        guard !isFocused else { return }
        state.withLock { current in
            current.pressedKeys.removeAll()
            current.isShiftPressed = false
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.shouldTogglePlayback = false
            current.shouldResetView = false
            current.sceneStep = 0
        }
    }

    func setMovementKey(_ key: ThresholdMacMovementKey, isPressed: Bool) {
        state.withLock { current in
            if isPressed {
                current.pressedKeys.insert(key)
            } else {
                current.pressedKeys.remove(key)
            }
        }
    }

    func setShiftPressed(_ isPressed: Bool) {
        state.withLock { current in
            current.isShiftPressed = isPressed
        }
    }

    func addOrbit(delta: SIMD2<Float>) {
        state.withLock { current in
            current.orbitDelta += delta
        }
    }

    func addPan(delta: SIMD2<Float>) {
        state.withLock { current in
            current.panDelta += delta
        }
    }

    func addZoom(delta: Float) {
        state.withLock { current in
            current.zoomDelta += delta
        }
    }

    func requestPlaybackToggle() {
        state.withLock { current in
            current.shouldTogglePlayback = true
        }
    }

    func requestReset() {
        state.withLock { current in
            current.shouldResetView = true
        }
    }

    func requestSceneStep(_ step: Int) {
        state.withLock { current in
            current.sceneStep += step
        }
    }

    func consumeFrame() -> ThresholdMacInputFrame {
        state.withLock { current in
            let frame = ThresholdMacInputFrame(
                pressedKeys: current.pressedKeys,
                isShiftPressed: current.isShiftPressed,
                orbitDelta: current.orbitDelta,
                panDelta: current.panDelta,
                zoomDelta: current.zoomDelta,
                shouldTogglePlayback: current.shouldTogglePlayback,
                shouldResetView: current.shouldResetView,
                sceneStep: current.sceneStep
            )
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.shouldTogglePlayback = false
            current.shouldResetView = false
            current.sceneStep = 0
            return frame
        }
    }
}

#if os(macOS)
private final class ThresholdMacInteractiveView: MTKView {
    private enum DragMode {
        case orbit
        case pan
    }

    weak var inputDelegate: (any ThresholdMacViewportInputDelegate)?
    private var dragMode: DragMode?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        dragMode = nil
        inputDelegate?.viewportDidChangeFocus(false)
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        beginInteraction(mode: event.modifierFlags.contains(.option) ? .pan : .orbit)
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .orbit)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        beginInteraction(mode: .pan)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .pan)
    }

    override func rightMouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        beginInteraction(mode: .pan)
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event, fallbackMode: .pan)
    }

    override func otherMouseUp(with event: NSEvent) {
        dragMode = nil
    }

    override func scrollWheel(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        inputDelegate?.viewportDidChangeFocus(true)
        let multiplier: Float = event.hasPreciseScrollingDeltas ? 1.0 : 6.0
        inputDelegate?.viewportDidZoom(delta: Float(event.scrollingDeltaY) * multiplier)
    }

    override func magnify(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        inputDelegate?.viewportDidChangeFocus(true)
        inputDelegate?.viewportDidZoom(delta: -Float(event.magnification) * 18.0)
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event, isPressed: true) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if handleKey(event, isPressed: false) {
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputDelegate?.viewportDidChangeShift(event.modifierFlags.contains(.shift))
        super.flagsChanged(with: event)
    }

    private func beginInteraction(mode: DragMode) {
        _ = window?.makeFirstResponder(self)
        inputDelegate?.viewportDidChangeFocus(true)
        dragMode = mode
    }

    private func handleDrag(_ event: NSEvent, fallbackMode: DragMode) {
        let delta = SIMD2<Float>(Float(event.deltaX), Float(event.deltaY))
        guard simd_length_squared(delta) > 0 else { return }

        let activeMode: DragMode
        if event.modifierFlags.contains(.option) {
            activeMode = .pan
        } else {
            activeMode = dragMode ?? fallbackMode
        }

        switch activeMode {
        case .orbit:
            inputDelegate?.viewportDidOrbit(delta: delta)
        case .pan:
            inputDelegate?.viewportDidPan(delta: delta)
        }
    }

    private func handleKey(_ event: NSEvent, isPressed: Bool) -> Bool {
        // Left/right arrows switch jumping-off scenes. Handled via virtual key
        // codes (123 = left, 124 = right) since arrow keys carry function-key
        // unicode rather than plain characters. Fire once per press (not on
        // auto-repeat) and consume both down and up to suppress the system beep.
        switch event.keyCode {
        case 123:
            if isPressed && !event.isARepeat {
                inputDelegate?.viewportDidRequestSceneStep(-1)
            }
            return true
        case 124:
            if isPressed && !event.isARepeat {
                inputDelegate?.viewportDidRequestSceneStep(1)
            }
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return false
        }

        var handled = false
        for character in characters {
            switch character {
            case "w":
                inputDelegate?.viewportDidChangeKey(.forward, isPressed: isPressed)
                handled = true
            case "s":
                inputDelegate?.viewportDidChangeKey(.backward, isPressed: isPressed)
                handled = true
            case "a":
                inputDelegate?.viewportDidChangeKey(.left, isPressed: isPressed)
                handled = true
            case "d":
                inputDelegate?.viewportDidChangeKey(.right, isPressed: isPressed)
                handled = true
            case " ":
                if isPressed && !event.isARepeat {
                    inputDelegate?.viewportDidTogglePlayback()
                }
                handled = true
            case "r":
                if isPressed && !event.isARepeat {
                    inputDelegate?.viewportDidRequestReset()
                }
                handled = true
            default:
                break
            }
        }

        return handled
    }
}

struct ThresholdMacRenderView: NSViewRepresentable {
    let appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = ThresholdMacInteractiveView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1.0)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.inputDelegate = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.configure(view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.appModel = appModel
        (nsView as? ThresholdMacInteractiveView)?.inputDelegate = context.coordinator
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        nsView.delegate = nil
        (nsView as? ThresholdMacInteractiveView)?.inputDelegate = nil
        coordinator.tearDown()
    }

    final class Coordinator: NSObject, MTKViewDelegate, ThresholdMacViewportInputDelegate {
        var appModel: AppModel
        private let inputController = ThresholdMacInputController()
        private var renderer: ThresholdMacRenderer?

        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
        }

        @MainActor
        func configure(_ view: MTKView) {
            appModel.rendererStartupWarmupComplete = false
            guard let device = view.device,
                  let metalLayer = view.layer as? CAMetalLayer else { return }
            metalLayer.device = device
            metalLayer.pixelFormat = view.colorPixelFormat
            metalLayer.framebufferOnly = true
            metalLayer.drawableSize = view.drawableSize
            renderer = ThresholdMacRenderer(device: device,
                                            appModel: appModel,
                                            inputController: inputController,
                                            metalLayer: metalLayer,
                                            colorPixelFormat: view.colorPixelFormat,
                                            depthPixelFormat: view.depthStencilPixelFormat,
                                            clearColor: view.clearColor)
            renderer?.drawableSizeDidChange(view.drawableSize)
            appModel.rendererStartupWarmupComplete = renderer != nil
        }

        func tearDown() {
            inputController.setFocus(false)
            renderer = nil
            Task { @MainActor [appModel] in
                appModel.rendererStartupWarmupComplete = false
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeDidChange(size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(appModel: appModel)
        }

        func viewportDidChangeFocus(_ isFocused: Bool) {
            inputController.setFocus(isFocused)
        }

        func viewportDidOrbit(delta: SIMD2<Float>) {
            inputController.addOrbit(delta: delta)
        }

        func viewportDidPan(delta: SIMD2<Float>) {
            inputController.addPan(delta: delta)
        }

        func viewportDidZoom(delta: Float) {
            inputController.addZoom(delta: delta)
        }

        func viewportDidChangeKey(_ key: ThresholdMacMovementKey, isPressed: Bool) {
            inputController.setMovementKey(key, isPressed: isPressed)
        }

        func viewportDidChangeShift(_ isPressed: Bool) {
            inputController.setShiftPressed(isPressed)
        }

        func viewportDidTogglePlayback() {
            inputController.requestPlaybackToggle()
        }

        func viewportDidRequestReset() {
            inputController.requestReset()
        }

        func viewportDidRequestSceneStep(_ step: Int) {
            inputController.requestSceneStep(step)
        }
    }
}
#endif

/// Lock-protected cache of function-constant–specialized `fragmentShaderMono`
/// pipelines for the macOS renderer. Specializing on iteration/ray-step/fractal
/// counts lets the Metal compiler fully unroll the `Map()` and `Scene()` loops
/// and devirtualize the DE dispatch — the same optimization the visionOS
/// `Renderer` already performs. Builds run asynchronously off the render thread;
/// the generic pipeline is used until the specialized variant is ready.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`, so the async
/// `makeRenderPipelineState` completion handler can safely store results.
private final class MacSpecializedPipelineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: MTLRenderPipelineState] = [:]
    private var pending: Set<String> = []

    func pipeline(for key: String) -> MTLRenderPipelineState? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// Returns `true` if the caller should kick off a build (not cached and not
    /// already in flight). Marks the key pending so concurrent frames don't
    /// schedule duplicate compiles.
    func beginBuildIfNeeded(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cache[key] != nil || pending.contains(key) { return false }
        pending.insert(key)
        return true
    }

    func store(_ pipeline: MTLRenderPipelineState, for key: String) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = pipeline
        pending.remove(key)
    }

    func failBuild(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        pending.remove(key)
    }
}

private final class ThresholdMacRenderer {
    private enum SetupError: Error {
        case badVertexDescriptor
        case metalLibraryUnavailable
    }

    private struct CachedMeshBinding {
        let bufferIndex: Int
        let buffer: MTLBuffer
        let offset: Int
    }

    /// Mirrors the `MacMotionParams` struct in Shaders.metal (Stage B temporal
    /// upscaling). Bound only to the motion-vector pass — never the shared
    /// `Uniforms`.
    private struct MacMotionParams {
        var currentInvViewProj: matrix_float4x4
        var currentViewProjNoJitter: matrix_float4x4
        var previousViewProjNoJitter: matrix_float4x4
    }

    private struct TemporalInvalidationKey: Equatable {
        let fractalType: Int32
        let fractalIterations: Int
        let maxRaySteps: Int
        let minDistance: Int32
        let fractalScale: Int32
        let foldingLimit: Int32
        let sphereRadius: Int32
        let colorIterations: Int32
        let sphericalInversionMode: Int32
        let sphericalInversionRadius: Int32
        let safetyBubbleEnabled: Bool
        let safetyBubbleRadius: Int32
        let safetyBubbleShape: Int32
        let safetyBubbleFadeEnabled: Bool
        let safetyBubbleFadeWidth: Int32
        let safetyBubbleStrength: Int32
        let formulaParams: SIMD16<Int32>

        init(settings: RenderSettingsSnapshot) {
            fractalType = settings.fractalType.rawValue
            fractalIterations = settings.fractalIterations
            maxRaySteps = settings.maxRaySteps
            minDistance = Self.quantize(settings.minDistance)
            fractalScale = Self.quantize(settings.fractalScale)
            foldingLimit = Self.quantize(settings.foldingLimit)
            sphereRadius = Self.quantize(settings.sphereRadius)
            colorIterations = Self.quantize(settings.colorIterations)
            sphericalInversionMode = settings.sphericalInversionMode.rawValue
            sphericalInversionRadius = Self.quantize(settings.sphericalInversionRadius)
            safetyBubbleEnabled = settings.safetyBubbleEnabled
            safetyBubbleRadius = Self.quantize(settings.safetyBubbleRadius)
            safetyBubbleShape = Self.quantize(settings.safetyBubbleShape)
            safetyBubbleFadeEnabled = settings.safetyBubbleFadeEnabled
            safetyBubbleFadeWidth = Self.quantize(settings.safetyBubbleFadeWidth)
            safetyBubbleStrength = Self.quantize(settings.safetyBubbleStrength)
            formulaParams = SIMD16<Int32>(
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 0)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 1)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 2)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 3)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 4)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 5)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 6)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 7)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 8)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 9)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 10)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 11)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 12)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 13)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 14)),
                Self.quantize(FormulaCatalog.getParam(settings.formulaParams, index: 15))
            )
        }

        private static func quantize(_ value: Float) -> Int32 {
            Int32(clamping: Int((value * 10_000).rounded()))
        }
    }

    private static let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
    private static let maxBuffersInFlight = 2
    private static let defaultTargetPosition = SIMD3<Float>(0.1, 0.1, 0.1)
    private static let minDetailScale: Float = 0.05
    private static let maxDetailScale: Float = 40.0
    private static let mouseRotationSpeed: Float = 0.006
    private static let mousePanSpeed: Float = 0.003
    private static let scrollZoomSpeed: Float = 0.035
    private static let keyboardMoveSpeed: Float = 1.6

    private let device: MTLDevice
    private let metalLayer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let depthPixelFormat: MTLPixelFormat
    private let colorPixelFormat: MTLPixelFormat
    private let vertexDescriptor: MTLVertexDescriptor
    private let specializedPipelineCache = MacSpecializedPipelineCache()
    private let spatialUpscaler: MacSpatialUpscaler
    private let temporalUpscaler: MacTemporalUpscaler
    private let blitPipelineState: MTLRenderPipelineState?
    private let motionPipelineState: MTLRenderPipelineState?
    private let clearColor: MTLClearColor
    private let inputController: ThresholdMacInputController
    private let uiUpdateCoordinator: UIUpdateCoordinator
    private let parameterUpdateCoordinator: ParameterUpdateCoordinator
    private let mesh: MTKMesh
    private let meshBindings: [CachedMeshBinding]
    private let uniformBuffers: [MTLBuffer]
    private let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    private let baseRotationMatrix = matrix4x4_rotation(radians: -.pi / 2, axis: [0, 1, 0])
    private let startTime = CACurrentMediaTime()

    private var uniformBufferIndex = 0
    private var lastFrameTime = CACurrentMediaTime()
    private var smoothedFPS: Double = 0
    private var smoothedScale: Float = 1.0
    private var smoothedMaxViewDistance: Float = RenderSettings.maxViewDistance
    private var drawableSize: CGSize = .zero
    private var depthTexture: MTLTexture?

    // Stage B temporal-upscaling state. Motion vectors reproject world positions
    // (reconstructed from the offscreen depth) through the previous frame's
    // un-jittered view-projection; the projection is sub-pixel jittered per frame
    // so the temporal scaler can resolve detail below native resolution.
    private var motionCurrentInvViewProj = matrix_identity_float4x4
    private var motionCurrentViewProjNoJitter = matrix_identity_float4x4
    private var motionPreviousViewProjNoJitter = matrix_identity_float4x4
    private var hasPreviousMotionMatrices = false
    private var currentJitterNDC = SIMD2<Float>.zero
    private var currentJitterPixels = SIMD2<Float>.zero
    private var haltonIndex: UInt32 = 0
    private var wasTemporalActive = false
    private var temporalInvalidationKey: TemporalInvalidationKey?

    // Shared music-reactive engine — same type used by the visionOS `Renderer`,
    // so the response-curve / LFO / dispatch math lives in exactly one place.
    private let musicReactiveEngine = MusicReactiveEngine()

    // Tilt-to-orbit sensor. On macOS this is the Intel-MacBook Sudden Motion
    // Sensor (IOKit); on iPad it is the CoreMotion gyroscope/attitude reader.
    // Both expose the same `TiltMotionSensor` interface so `applyTiltControl`
    // is platform-agnostic.
    private let motionSensor: any TiltMotionSensor = PlatformTiltSensor()
    private var wasTiltControlEnabled = false

    init?(device: MTLDevice,
                    appModel: AppModel,
                    inputController: ThresholdMacInputController,
          metalLayer: CAMetalLayer,
          colorPixelFormat: MTLPixelFormat,
          depthPixelFormat: MTLPixelFormat,
          clearColor: MTLClearColor) {
        self.device = device
        self.metalLayer = metalLayer
        self.depthPixelFormat = depthPixelFormat
        self.colorPixelFormat = colorPixelFormat
        self.clearColor = clearColor
                self.inputController = inputController
                self.uiUpdateCoordinator = UIUpdateCoordinator(appModel: appModel)
                self.parameterUpdateCoordinator = ParameterUpdateCoordinator(appModel: appModel)

        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        let builtPipeline: MTLRenderPipelineState
        let builtMesh: MTKMesh
        let builtVertexDescriptor = Self.buildMetalVertexDescriptor()
        do {
            builtPipeline = try Self.buildRenderPipeline(device: device, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, vertexDescriptor: builtVertexDescriptor)
            builtMesh = try Self.buildMesh(device: device, vertexDescriptor: builtVertexDescriptor)
        } catch {
            print("ThresholdMac renderer setup failed: \(error)")
            return nil
        }
        pipelineState = builtPipeline
        vertexDescriptor = builtVertexDescriptor
        mesh = builtMesh

        spatialUpscaler = MacSpatialUpscaler(device: device,
                                             colorFormat: colorPixelFormat,
                                             depthFormat: depthPixelFormat)
        temporalUpscaler = MacTemporalUpscaler(device: device,
                                               colorFormat: colorPixelFormat,
                                               depthFormat: depthPixelFormat)
        blitPipelineState = Self.buildBlitPipeline(device: device, colorPixelFormat: colorPixelFormat)
        motionPipelineState = Self.buildMotionPipeline(device: device)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.depthState = depthState

        var buffers: [MTLBuffer] = []
        for index in 0..<Self.maxBuffersInFlight {
            guard let buffer = device.makeBuffer(length: Self.alignedUniformsSize, options: .storageModeShared) else { return nil }
            buffer.label = "ThresholdMac Uniforms \(index)"
            buffers.append(buffer)
        }
        uniformBuffers = buffers

        meshBindings = builtMesh.vertexDescriptor.layouts.enumerated().compactMap { index, layout in
            guard let layout = layout as? MDLVertexBufferLayout, layout.stride != 0 else { return nil }
            let vertexBuffer = builtMesh.vertexBuffers[index]
            return CachedMeshBinding(bufferIndex: index, buffer: vertexBuffer.buffer, offset: vertexBuffer.offset)
        }
    }

    func drawableSizeDidChange(_ size: CGSize) {
        drawableSize = size
        metalLayer.drawableSize = size
    }

    func draw(appModel: AppModel) {
        guard appModel.isAppActive,
              drawableSize.width > 1,
              drawableSize.height > 1,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        let drawableWidth = drawable.texture.width
        let drawableHeight = drawable.texture.height

        // Decide whether to render at reduced resolution and MetalFX-upscale to
        // the drawable. The offscreen target stays in the drawable's sRGB color
        // format so the raymarch pipeline needs no changes; only sub-native
        // scales engage a scaler. Temporal upscaling is preferred when supported
        // (better stability/detail); the spatial scaler is the fallback.
        let resolutionScale = appModel.renderSettings.resolutionScale
        var temporalPass: (color: MTLTexture, depth: MTLTexture, motion: MTLTexture, output: MTLTexture)?
        var spatialPass: (color: MTLTexture, depth: MTLTexture, output: MTLTexture)?
        if resolutionScale < 0.985, blitPipelineState != nil {
            let inputWidth = max(1, Int((Float(drawableWidth) * resolutionScale).rounded()))
            let inputHeight = max(1, Int((Float(drawableHeight) * resolutionScale).rounded()))
            // MetalFX temporal supports at most 3× per dimension; clamp the
            // temporal input up to `output / 3` so the lowest slider settings
            // stay on the temporal path instead of falling back to spatial.
            let minTemporalWidth = Int((Double(drawableWidth) / MacTemporalUpscaler.maxScaleFactor).rounded(.up))
            let minTemporalHeight = Int((Double(drawableHeight) / MacTemporalUpscaler.maxScaleFactor).rounded(.up))
            let temporalInputWidth = max(inputWidth, minTemporalWidth)
            let temporalInputHeight = max(inputHeight, minTemporalHeight)
            if motionPipelineState != nil,
               temporalUpscaler.prepare(inputWidth: temporalInputWidth,
                                        inputHeight: temporalInputHeight,
                                        outputWidth: drawableWidth,
                                        outputHeight: drawableHeight),
               let color = temporalUpscaler.colorTexture,
               let depth = temporalUpscaler.depthTexture,
               let motion = temporalUpscaler.motionTexture,
               let output = temporalUpscaler.outputTexture {
                temporalPass = (color, depth, motion, output)
            } else if spatialUpscaler.prepare(inputWidth: inputWidth,
                                              inputHeight: inputHeight,
                                              outputWidth: drawableWidth,
                                              outputHeight: drawableHeight),
                      let color = spatialUpscaler.colorTexture,
                      let depth = spatialUpscaler.depthTexture,
                      let output = spatialUpscaler.outputTexture {
                spatialPass = (color, depth, output)
            }
        }

        // Sub-pixel projection jitter only applies on the temporal path (the
        // scaler needs jittered samples to accumulate detail). Compute it before
        // `writeUniforms` so `makeUniforms` can bake it into the projection.
        if temporalPass != nil {
            haltonIndex = haltonIndex &+ 1
            let jx = Self.halton(haltonIndex, base: 2) - 0.5
            let jy = Self.halton(haltonIndex, base: 3) - 0.5
            currentJitterPixels = SIMD2<Float>(jx, jy)
            let w = Float(max(temporalUpscaler.inputSize.width, 1))
            let h = Float(max(temporalUpscaler.inputSize.height, 1))
            currentJitterNDC = SIMD2<Float>(2.0 * jx / w, 2.0 * jy / h)
        } else {
            currentJitterPixels = .zero
            currentJitterNDC = .zero
        }

        // The direct (native-resolution) path renders straight into the drawable
        // and needs the drawable-sized depth target.
        let directPassDescriptor: MTLRenderPassDescriptor?
        if temporalPass == nil, spatialPass == nil {
            guard let descriptor = makeRenderPassDescriptor(drawable: drawable) else { return }
            directPassDescriptor = descriptor
        } else {
            directPassDescriptor = nil
        }

        guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
            inFlightSemaphore.signal()
        }

        let uniformBuffer = uniformBuffers[uniformBufferIndex]
        uniformBufferIndex = (uniformBufferIndex + 1) % uniformBuffers.count
        writeUniforms(to: uniformBuffer, appModel: appModel)

        let activePipeline = resolveActivePipeline(appModel: appModel)

        if let temporalPass, let blitPipelineState, let motionPipelineState {
            // 1. Raymarch into the low-resolution offscreen target. Depth is
            //    stored (not discarded) so the motion pass + scaler can read it.
            let offscreenDescriptor = makeOffscreenRenderPassDescriptor(color: temporalPass.color,
                                                                        depth: temporalPass.depth,
                                                                        storeDepth: true)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenDescriptor) else {
                commandBuffer.commit()
                return
            }
            encodeRaymarch(into: encoder, pipeline: activePipeline, uniformBuffer: uniformBuffer)
            encoder.endEncoding()

            // 2. Motion-vector pass: reconstruct world position from depth and
            //    reproject through the previous frame's view-projection.
            let motionDescriptor = MTLRenderPassDescriptor()
            motionDescriptor.colorAttachments[0].texture = temporalPass.motion
            motionDescriptor.colorAttachments[0].loadAction = .dontCare
            motionDescriptor.colorAttachments[0].storeAction = .store
            guard let motionEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: motionDescriptor) else {
                commandBuffer.commit()
                return
            }
            motionEncoder.setRenderPipelineState(motionPipelineState)
            motionEncoder.setFragmentTexture(temporalPass.depth, index: 0)
            var motionParams = MacMotionParams(currentInvViewProj: motionCurrentInvViewProj,
                                               currentViewProjNoJitter: motionCurrentViewProjNoJitter,
                                               previousViewProjNoJitter: motionPreviousViewProjNoJitter)
            motionEncoder.setFragmentBytes(&motionParams,
                                           length: MemoryLayout<MacMotionParams>.stride,
                                           index: 0)
            motionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            motionEncoder.endEncoding()

            // 3. MetalFX temporal upscale → full-resolution output. Reset history
            //    when temporal scaling has just (re)engaged.
            temporalUpscaler.encode(commandBuffer: commandBuffer,
                                    jitterPixels: currentJitterPixels,
                                    forceReset: !wasTemporalActive)

            // 4. Blit the upscaled output to the drawable.
            let blitDescriptor = MTLRenderPassDescriptor()
            blitDescriptor.colorAttachments[0].texture = drawable.texture
            blitDescriptor.colorAttachments[0].loadAction = .dontCare
            blitDescriptor.colorAttachments[0].storeAction = .store
            guard let blitEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitDescriptor) else {
                commandBuffer.commit()
                return
            }
            blitEncoder.setRenderPipelineState(blitPipelineState)
            blitEncoder.setFragmentTexture(temporalPass.output, index: 0)
            blitEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            blitEncoder.endEncoding()

            wasTemporalActive = true
        } else if let spatialPass, let blitPipelineState {
            // 1. Raymarch into the low-resolution offscreen target.
            let offscreenDescriptor = makeOffscreenRenderPassDescriptor(color: spatialPass.color,
                                                                        depth: spatialPass.depth)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenDescriptor) else {
                commandBuffer.commit()
                return
            }
            encodeRaymarch(into: encoder, pipeline: activePipeline, uniformBuffer: uniformBuffer)
            encoder.endEncoding()

            // 2. MetalFX spatial upscale → full-resolution output.
            spatialUpscaler.encode(commandBuffer: commandBuffer)

            // 3. Blit the upscaled output to the drawable.
            let blitDescriptor = MTLRenderPassDescriptor()
            blitDescriptor.colorAttachments[0].texture = drawable.texture
            blitDescriptor.colorAttachments[0].loadAction = .dontCare
            blitDescriptor.colorAttachments[0].storeAction = .store
            guard let blitEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: blitDescriptor) else {
                commandBuffer.commit()
                return
            }
            blitEncoder.setRenderPipelineState(blitPipelineState)
            blitEncoder.setFragmentTexture(spatialPass.output, index: 0)
            blitEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            blitEncoder.endEncoding()

            wasTemporalActive = false
        } else if let directPassDescriptor {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: directPassDescriptor) else {
                commandBuffer.commit()
                return
            }
            encodeRaymarch(into: encoder, pipeline: activePipeline, uniformBuffer: uniformBuffer)
            encoder.endEncoding()

            wasTemporalActive = false
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encodes the raymarch draw into an active render encoder. Shared by the
    /// direct (native) and offscreen (upscaled) render passes.
    private func encodeRaymarch(into encoder: MTLRenderCommandEncoder,
                                pipeline: MTLRenderPipelineState,
                                uniformBuffer: MTLBuffer) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        for binding in meshBindings {
            encoder.setVertexBuffer(binding.buffer, offset: binding.offset, index: binding.bufferIndex)
        }
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: BufferIndex.uniforms.rawValue)

        for submesh in mesh.submeshes {
            encoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                          indexCount: submesh.indexCount,
                                          indexType: submesh.indexType,
                                          indexBuffer: submesh.indexBuffer.buffer,
                                          indexBufferOffset: submesh.indexBuffer.offset)
        }
    }

    private func makeOffscreenRenderPassDescriptor(color: MTLTexture, depth: MTLTexture, storeDepth: Bool = false) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = color
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = storeDepth ? .store : .dontCare
        descriptor.depthAttachment.clearDepth = 1.0
        return descriptor
    }

    /// Mirrors the visionOS `FunctionConstantConfig.specializedMandelbulbPower`:
    /// returns the integer Mandelbulb power for `fastPowR` dead-code elimination
    /// when the power is a near-integer from the supported set, else `nil`.
    private static func specializedMandelbulbPower(fractalType: FractalModelType,
                                                   formulaParams: FormulaParams) -> Int32? {
        guard fractalType == .mandelbulb else { return nil }
        let rawPower = FormulaCatalog.getParam(formulaParams, index: 0)
        let rounded = roundf(rawPower)
        guard abs(rawPower - rounded) < 0.01,
              [2, 3, 4, 5, 6, 8, 10, 12, 16].contains(Int(rounded)) else {
            return nil
        }
        return Int32(rounded)
    }

    /// Picks the function-constant–specialized `fragmentShaderMono` pipeline for
    /// the current settings when available, otherwise the generic pipeline.
    /// Kicks off an async build the first time a configuration is seen so future
    /// frames get the fully-unrolled fast path without hitching the render thread.
    /// Updates `appModel.isUsingSpecializedPipeline` (drives the bolt indicator).
    private func resolveActivePipeline(appModel: AppModel) -> MTLRenderPipelineState {
        let settings = appModel.renderSettings
        let iterations = Int32(settings.fractalIterations)
        let raySteps = Int32(settings.maxRaySteps)
        let fractalType = settings.fractalType.rawValue
        let colorIterations = Int32(settings.colorIterations)
        let power = Self.specializedMandelbulbPower(
            fractalType: settings.fractalType,
            formulaParams: settings.formulaParams
        )

        let powerKey = power.map { "_P\($0)" } ?? ""
        let key = "FT\(fractalType)_FI\(iterations)_RS\(raySteps)_CI\(colorIterations)\(powerKey)"

        if let specialized = specializedPipelineCache.pipeline(for: key) {
            appModel.isUsingSpecializedPipeline = true
            return specialized
        }

        // Not ready yet — schedule a background build and use the generic
        // pipeline for this frame.
        if specializedPipelineCache.beginBuildIfNeeded(key) {
            buildSpecializedPipeline(
                key: key,
                iterations: iterations,
                raySteps: raySteps,
                fractalType: fractalType,
                colorIterations: colorIterations,
                power: power
            )
        }
        appModel.isUsingSpecializedPipeline = false
        return pipelineState
    }

    /// Asynchronously compiles a specialized `fragmentShaderMono` pipeline and
    /// stores it in the cache. Function-constant specialization unrolls the
    /// iteration/ray-step loops and devirtualizes the fractal DE dispatch.
    private func buildSpecializedPipeline(key: String,
                                          iterations: Int32,
                                          raySteps: Int32,
                                          fractalType: Int32,
                                          colorIterations: Int32,
                                          power: Int32?) {
        let cache = specializedPipelineCache
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "screenshotVertexShader") else {
            cache.failBuild(key)
            return
        }

        // Metal function-constant indices (mirrors the visionOS
        // `FunctionConstantIndex`, which is unavailable on macOS because it
        // lives in a CompositorServices-only file): 0=fractalIterations,
        // 6=maxRaySteps, 7=fractalType, 9=colorIterations, 12=mandelbulbPower.
        let constants = MTLFunctionConstantValues()
        var fi = iterations
        constants.setConstantValue(&fi, type: .int, index: 0)
        var rs = raySteps
        constants.setConstantValue(&rs, type: .int, index: 6)
        var ft = fractalType
        constants.setConstantValue(&ft, type: .int, index: 7)
        var ci = colorIterations
        constants.setConstantValue(&ci, type: .int, index: 9)
        if var p = power {
            constants.setConstantValue(&p, type: .int, index: 12)
        }

        let fragmentFunction: MTLFunction
        do {
            fragmentFunction = try library.makeFunction(name: "fragmentShaderMono", constantValues: constants)
        } catch {
            cache.failBuild(key)
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Specialized [\(key)]"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        device.makeRenderPipelineState(descriptor: descriptor) { pipeline, _ in
            if let pipeline {
                cache.store(pipeline, for: key)
            } else {
                cache.failBuild(key)
            }
        }
    }

    private func makeRenderPassDescriptor(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor? {
        guard let depthTexture = depthTexture(width: drawable.texture.width, height: drawable.texture.height) else {
            return nil
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1.0
        return descriptor
    }

    private func depthTexture(width: Int, height: Int) -> MTLTexture? {
        if let depthTexture, depthTexture.width == width, depthTexture.height == height {
            return depthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthPixelFormat,
                                                                  width: max(width, 1),
                                                                  height: max(height, 1),
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        #if os(iOS)
        descriptor.storageMode = .memoryless
        #else
        descriptor.storageMode = .private
        #endif
        depthTexture = device.makeTexture(descriptor: descriptor)
        depthTexture?.label = "ThresholdMac Depth"
        return depthTexture
    }

    private func writeUniforms(to buffer: MTLBuffer, appModel: AppModel) {
        let now = CACurrentMediaTime()
        let deltaTime = max(1.0 / 240.0, min(now - lastFrameTime, 1.0 / 15.0))
        lastFrameTime = now

        let settings = appModel.renderSettings
        applyDesktopInput(appModel: appModel, settings: settings, deltaTime: deltaTime)
        settings.interpolateToTargets(deltaTime: Float(deltaTime))
        settings.updateLimitFlash(deltaTime: Float(deltaTime))
        settings.updateColorSchemeTransition(deltaTime: Float(deltaTime))

        let isAudioMode = settings.lightingMode == .audioReactive ||
            settings.lightingMode == .visualizer ||
            settings.fractalAudioReactiveEnabled
        let hasActiveAudioSources = appModel.audioAnalyzer.isCapturing || appModel.appleMusicManager.isActive

        parameterUpdateCoordinator.scheduleParameterUpdates(
            shouldUpdateAnimation: settings.isAnimationPlaying,
            shouldUpdateAudio: isAudioMode && hasActiveAudioSources,
            deltaTime: deltaTime,
            currentTime: now
        )
        updateAudioLevels(appModel: appModel,
                          settings: settings,
                          isAudioMode: isAudioMode,
                          hasActiveAudioSources: hasActiveAudioSources)
        updateMusicReactiveParameters(appModel: appModel,
                                      settings: settings,
                                      isAudioMode: isAudioMode,
                                      hasActiveAudioSources: hasActiveAudioSources,
                                      deltaTime: Float(deltaTime))

        updateFPS(deltaTime: deltaTime)
        uiUpdateCoordinator.scheduleUIUpdate(fps: smoothedFPS,
                                             headHeightMeters: nil,
                                             currentTime: now)

        let snapshot = settings.snapshot()
        updateTemporalInvalidationState(settings: snapshot)
        let uniforms = makeUniforms(settings: snapshot, elapsedTime: Float(now - startTime), deltaTime: Float(deltaTime))
        let pointer = buffer.contents().bindMemory(to: UniformsArray.self, capacity: 1)
        pointer.pointee.uniforms.0 = uniforms
        pointer.pointee.uniforms.1 = uniforms
    }

    private func updateTemporalInvalidationState(settings: RenderSettingsSnapshot) {
        let newKey = TemporalInvalidationKey(settings: settings)
        if let oldKey = temporalInvalidationKey, oldKey != newKey {
            temporalUpscaler.requestReset()
            hasPreviousMotionMatrices = false
        }
        temporalInvalidationKey = newKey

        if settings.geometryState != .stable || settings.isGeometryGestureActive {
            temporalUpscaler.requestReset()
        }
    }

    private func applyDesktopInput(appModel: AppModel, settings: RenderSettings, deltaTime: TimeInterval) {
        applyTiltControl(settings: settings, deltaTime: deltaTime)

        let input = inputController.consumeFrame()

        if input.shouldResetView {
            resetDesktopView(settings: settings)
        }

        if input.sceneStep != 0 {
            let forward = input.sceneStep > 0
            Task { @MainActor [weak appModel] in
                appModel?.cycleJumpingOffScene(forward: forward)
            }
        }

        if input.shouldTogglePlayback {
            Task { @MainActor [weak appModel] in
                guard let appModel,
                      let animationManager = appModel.animationManager else { return }

                if animationManager.isPlaying {
                    animationManager.stop()
                    return
                }

                if animationManager.currentScene?.keyframes.count ?? 0 < 2 {
                    animationManager.currentScene = animationManager.scenes.first { $0.keyframes.count >= 2 }
                }
                animationManager.play()
            }
        }

        var targetRotation = settings.targetWorldRotation
        var targetDetailScale = settings.targetDetailScale
        var positionDelta = SIMD3<Float>.zero

        let gestureSensitivity = max(settings.gestureSensitivity / 10.0, 0.1)
        let translationSensitivity = settings.translationSensitivity

        if simd_length_squared(input.orbitDelta) > 0 {
            let yawAngle = -input.orbitDelta.x * Self.mouseRotationSpeed * gestureSensitivity
            let pitchAngle = -input.orbitDelta.y * Self.mouseRotationSpeed * gestureSensitivity
            let yawRotation = simd_quatf(angle: yawAngle, axis: SIMD3<Float>(0, 1, 0))
            let pitchRotation = simd_quatf(angle: pitchAngle, axis: SIMD3<Float>(1, 0, 0))
            let rotated = yawRotation * targetRotation * pitchRotation
            targetRotation = abs(simd_length_squared(rotated.vector) - 1.0) > 1e-4 ? rotated.normalized : rotated
        }

        if input.zoomDelta != 0 {
            let zoomFactor = exp(-input.zoomDelta * Self.scrollZoomSpeed * gestureSensitivity)
            targetDetailScale = min(Self.maxDetailScale, max(Self.minDetailScale, targetDetailScale * zoomFactor))
        }

        let zoomCompensation = simd_clamp(1.0 / pow(max(targetDetailScale, 0.01), 0.3), 0.5, 2.0)

        if simd_length_squared(input.panDelta) > 0 {
            let panScale = Self.mousePanSpeed * translationSensitivity * zoomCompensation
            positionDelta += SIMD3<Float>(input.panDelta.x * panScale, -input.panDelta.y * panScale, 0)
        }

        let moveStep = Float(deltaTime) * Self.keyboardMoveSpeed * translationSensitivity * zoomCompensation
        if input.isShiftPressed {
            if input.pressedKeys.contains(.forward) {
                positionDelta.y += moveStep
            }
            if input.pressedKeys.contains(.backward) {
                positionDelta.y -= moveStep
            }
        } else {
            if input.pressedKeys.contains(.forward) {
                positionDelta.z += moveStep
            }
            if input.pressedKeys.contains(.backward) {
                positionDelta.z -= moveStep
            }
        }
        if input.pressedKeys.contains(.left) {
            positionDelta.x -= moveStep
        }
        if input.pressedKeys.contains(.right) {
            positionDelta.x += moveStep
        }

        if positionDelta != .zero {
            if settings.isAnimationPlaying {
                settings.manualOffsetPosition = settings.manualOffsetPosition + positionDelta
            } else {
                settings.targetPosition = settings.targetPosition + positionDelta
            }
        }

        settings.targetWorldRotation = targetRotation
        settings.targetDetailScale = targetDetailScale
    }

    private func updateAudioLevels(appModel: AppModel,
                                   settings: RenderSettings,
                                   isAudioMode: Bool,
                                   hasActiveAudioSources: Bool) {
        guard isAudioMode else { return }

        guard hasActiveAudioSources else {
            settings.bassLevel = 0
            settings.midLevel = 0
            settings.trebleLevel = 0
            settings.beatIntensity = 0
            settings.audioLevel = 0
            return
        }

        let analyzer = appModel.audioAnalyzer
        let appleMusicManager = appModel.appleMusicManager
        let bassSensitivity = settings.bassSensitivity
        let midSensitivity = settings.midSensitivity
        let trebleSensitivity = settings.trebleSensitivity
        let beatSensitivity = settings.beatSensitivity

        var totalBass: Float = 0
        var totalMid: Float = 0
        var totalTreble: Float = 0
        var totalBeat: Float = 0
        var totalLevel: Float = 0
        var sourceCount: Float = 0

        if analyzer.isCapturing {
            totalBass += analyzer.bassLevel
            totalMid += analyzer.midLevel
            totalTreble += analyzer.trebleLevel
            totalBeat = max(totalBeat, analyzer.peakLevel * 0.7)
            totalLevel += analyzer.level
            sourceCount += 1
        }

        if appleMusicManager.isActive {
            totalBass += appleMusicManager.bassLevel
            totalMid += appleMusicManager.midLevel
            totalTreble += appleMusicManager.trebleLevel
            totalBeat = max(totalBeat, appleMusicManager.beatIntensity)
            totalLevel += appleMusicManager.overallLevel
            sourceCount += 1
        }

        guard sourceCount > 0 else {
            settings.bassLevel = 0
            settings.midLevel = 0
            settings.trebleLevel = 0
            settings.beatIntensity = 0
            settings.audioLevel = 0
            return
        }

        let inverseSourceCount = 1.0 / sourceCount
        settings.bassLevel = min(1.0, totalBass * inverseSourceCount * bassSensitivity)
        settings.midLevel = min(1.0, totalMid * inverseSourceCount * midSensitivity)
        settings.trebleLevel = min(1.0, totalTreble * inverseSourceCount * trebleSensitivity)
        settings.beatIntensity = min(1.0, totalBeat * beatSensitivity)
        settings.audioLevel = totalLevel * inverseSourceCount
    }

    private func updateMusicReactiveParameters(appModel: AppModel,
                                               settings: RenderSettings,
                                               isAudioMode: Bool,
                                               hasActiveAudioSources: Bool,
                                               deltaTime: Float) {
        guard isAudioMode, hasActiveAudioSources, settings.fractalAudioReactiveEnabled else {
            clearMusicReactiveLayersIfNeeded(appModel: appModel, settings: settings)
            return
        }

        // The aggregation in `updateAudioLevels` produced the per-band levels; the
        // shared engine applies damping, response curves, the LFO overlay, and dispatch.
        let bandLevels = BandLevels(bass: settings.bassLevel,
                                    mid: settings.midLevel,
                                    treble: settings.trebleLevel,
                                    beat: settings.beatIntensity,
                                    overall: settings.audioLevel)
        musicReactiveEngine.process(bandLevels: bandLevels,
                                    settings: settings,
                                    deltaTime: deltaTime,
                                    pipeline: appModel.parameterPipeline)
    }

    private func clearMusicReactiveLayersIfNeeded(appModel: AppModel, settings: RenderSettings) {
        musicReactiveEngine.reset(settings: settings, pipeline: appModel.parameterPipeline)
    }

    /// Reads the Sudden Motion Sensor and injects tilt as orbit input when
    /// tilt-control is enabled. Sustained tilt produces continuous orbit (tilt
    /// the laptop to spin the fractal; return it level to stop). No-op when the
    /// sensor is unavailable (Apple Silicon / desktops) or the setting is off.
    private func applyTiltControl(settings: RenderSettings, deltaTime: TimeInterval) {
        let enabled = settings.macTiltControlEnabled
        // No-op on macOS (the SMS samples on demand); on iOS this starts/stops
        // CoreMotion so it doesn't run while tilt control is off.
        motionSensor.setActive(enabled)
        guard enabled, motionSensor.isAvailable else {
            wasTiltControlEnabled = enabled
            return
        }

        // Recenter on the enable edge so the current pose reads as level.
        if !wasTiltControlEnabled {
            motionSensor.calibrate()
        }
        wasTiltControlEnabled = enabled

        guard let tilt = motionSensor.read() else { return }

        // Ignore small tilts so a resting laptop doesn't drift.
        let deadzone: Float = 0.04
        func shaped(_ v: Float) -> Float {
            let m = abs(v)
            guard m > deadzone else { return 0 }
            return (m - deadzone) * (v < 0 ? -1 : 1)
        }

        let roll = shaped(tilt.roll)
        let pitch = shaped(tilt.pitch)
        guard roll != 0 || pitch != 0 else { return }

        // Map tilt (g-relative) to an equivalent per-frame mouse-orbit delta so
        // it flows through the same sensitivity pipeline as drag orbiting.
        // Normalized to 60 fps so the spin rate is frame-rate independent.
        let frameScale = Float(deltaTime) * 60.0
        let tiltOrbitGain: Float = 26.0
        let orbit = SIMD2<Float>(roll * tiltOrbitGain * frameScale,
                                 pitch * tiltOrbitGain * frameScale)
        inputController.addOrbit(delta: orbit)
    }

    private func resetDesktopView(settings: RenderSettings) {
        if settings.isAnimationPlaying {
            settings.clearAnimationManualOffsets()
        } else {
            settings.position = Self.defaultTargetPosition
            settings.targetPosition = Self.defaultTargetPosition
        }
        settings.resetDetailTransform()
        // Discard temporal history so the camera jump doesn't smear.
        temporalUpscaler.requestReset()
    }

    private func updateFPS(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        let instantFPS = 1.0 / deltaTime
        let smoothFactor = 1.0 - exp(-10.0 * deltaTime)
        smoothedFPS += (instantFPS - smoothedFPS) * smoothFactor
    }

    private func makeUniforms(settings: RenderSettingsSnapshot, elapsedTime: Float, deltaTime: Float) -> Uniforms {
        let smoothFactor = 1.0 - exp(-15.0 * deltaTime)
        smoothedScale += (settings.scale - smoothedScale) * smoothFactor

        let userRotationMatrix = matrix4x4_from_quaternion(settings.worldRotation)
        let combinedRotationMatrix = userRotationMatrix * baseRotationMatrix
        let effectiveScale = smoothedScale * settings.detailScale
        let translationMatrix = matrix4x4_translation(settings.position.x, settings.position.y, settings.position.z)
        let scaleMatrix = matrix4x4_scale(effectiveScale, effectiveScale, effectiveScale)
        let modelMatrix = translationMatrix * combinedRotationMatrix * scaleMatrix

        let isKleinianFamily = settings.fractalType == .kleinian || settings.fractalType == .theliPseudoKleinian
        let traceScaleFloor: Float = isKleinianFamily ? 0.02 : 0.15
        let traceScale = max(effectiveScale, traceScaleFloor)
        let maxViewDistanceCap: Float = isKleinianFamily ? 420.0 : 80.0
        let baseViewDistance: Float = isKleinianFamily ? RenderSettings.maxViewDistance * 2.0 : RenderSettings.maxViewDistance
        let targetMaxViewDistance = min(maxViewDistanceCap, baseViewDistance / traceScale)
        let maxViewDistanceSpeed: Float = targetMaxViewDistance > smoothedMaxViewDistance ? 30.0 : 10.0
        let maxViewDistanceBlend = 1.0 - exp(-maxViewDistanceSpeed * deltaTime)
        smoothedMaxViewDistance += (targetMaxViewDistance - smoothedMaxViewDistance) * maxViewDistanceBlend
        let maxViewDistance = max(4.0, min(maxViewDistanceCap, smoothedMaxViewDistance))

        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        let projection = RenderPrecompute.makePerspectiveProjection(fovyRadians: Float.pi / 3, aspect: aspect, nearZ: 0.01, farZ: 500.0)
        let viewMatrix = matrix4x4_translation(0, 0, -3.0)
        let modelView = viewMatrix * modelMatrix
        let inverseModelView = modelView.inverse

        // Stage B: bake the sub-pixel jitter into the projection (zero when the
        // temporal path is inactive, so this is a no-op for the other paths) and
        // cache the matrices the motion-vector pass needs. The reconstruction
        // inverse uses the *jittered* view-projection (matching the jittered
        // depth); motion is measured from the *un-jittered* current/previous
        // view-projections so it carries pure geometric motion.
        var jitteredProjection = projection
        jitteredProjection.columns.2.x += currentJitterNDC.x
        jitteredProjection.columns.2.y += currentJitterNDC.y
        let viewProjNoJitter = projection * modelView
        let viewProjJittered = jitteredProjection * modelView
        motionPreviousViewProjNoJitter = hasPreviousMotionMatrices ? motionCurrentViewProjNoJitter : viewProjNoJitter
        motionCurrentViewProjNoJitter = viewProjNoJitter
        motionCurrentInvViewProj = viewProjJittered.inverse
        hasPreviousMotionMatrices = true

        let precomputedFractal = RenderPrecompute.makePrecomputedFractal(from: settings)
        let precomputedLighting = RenderPrecompute.makePrecomputedLighting(time: elapsedTime,
                                                               lightingMode: settings.lightingMode,
                                                               audioLevel: settings.audioLevel,
                                                               bassLevel: settings.bassLevel,
                                                               midLevel: settings.midLevel,
                                                               trebleLevel: settings.trebleLevel,
                                                               beatIntensity: settings.beatIntensity)
        let precomputedAudio = RenderPrecompute.makePrecomputedAudio(from: settings)
        var precomputedFog = RenderPrecompute.makePrecomputedFog(from: settings)
        if isKleinianFamily {
            let baseFog = precomputedFog.fog.x
            if baseFog > 1e-6 {
                let fogScale = min(1.0, max(0.08, traceScale / 0.15))
                let fogIntensity = baseFog * fogScale
                let inverseFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
                precomputedFog = PrecomputedFog(fog: SIMD4<Float>(fogIntensity, inverseFog, 0.0, 0.0), color: precomputedFog.color)
            }
        }

        let lightingWave = sin(elapsedTime * 1.2)
        let animatedColorMix = settings.lightingPlay ? min(max(settings.colorMix + lightingWave * 0.08, 0.0), 1.0) : settings.colorMix
        let baseGlow = settings.colorSchemeParams.glowIntensity
        let animatedGlow = settings.lightingPlay ? min(max(baseGlow + max(0, lightingWave) * 0.25, 0.0), 2.0) : baseGlow
        let scaleCorrectedBubbleRadius = settings.safetyBubbleRadius / max(effectiveScale, 0.001)
        let scaleCorrectedFadeWidth = settings.safetyBubbleFadeWidth / max(effectiveScale, 0.001)

        return Uniforms(projectionMatrix: jitteredProjection,
                        modelViewMatrix: modelView,
                        inverseModelViewMatrix: inverseModelView,
                        // Warm start is visionOS-only (FC_WARM_START compiled out
                        // of the Mac pipelines); these stay inert here.
                        previousViewProjMatrix: matrix_identity_float4x4,
                        previousInvViewProjMatrix: matrix_identity_float4x4,
                        time: elapsedTime,
                        minDistance: settings.minDistance,
                        fractalScale: settings.fractalScale,
                        fractalIterations: Int32(settings.fractalIterations),
                        maxRaySteps: Int32(settings.maxRaySteps),
                        maxViewDistance: maxViewDistance,
                        colorMix: animatedColorMix,
                        glowIntensity: animatedGlow,
                        foldingLimit: settings.foldingLimit,
                        sphereRadius: settings.sphereRadius,
                        safetyBubbleRadius: scaleCorrectedBubbleRadius,
                        safetyBubbleEnabled: settings.fractalType == .mandelbulb ? 0 : (settings.safetyBubbleEnabled ? 1 : 0),
                        safetyBubbleShape: settings.safetyBubbleShape,
                        safetyBubbleFadeEnabled: settings.safetyBubbleFadeEnabled ? 1 : 0,
                        safetyBubbleFadeWidth: scaleCorrectedFadeWidth,
                        safetyBubbleStrength: settings.fractalType == .mandelbulb ? 0.0 : settings.safetyBubbleStrength,
                        colorIterations: settings.colorIterations,
                        limitFlash: settings.limitFlash,
                        activeGesture: Int32(settings.activeGestureIndex),
                        warmStartEnabled: 0,
                        fractalType: settings.fractalType.rawValue,
                        lightingSoftness: settings.lightingSoftness,
                        sphericalInversionMode: settings.sphericalInversionMode.rawValue,
                        sphericalInversionRadius: settings.sphericalInversionRadius,
                        stepMultiplier: settings.stepMultiplier,
                        boundingSphereRadius: settings.estimatedBoundingSphereRadius,
                        springDisplacementX: settings.springDisplacement.x,
                        springDisplacementY: settings.springDisplacement.y,
                        springDisplacementZ: settings.springDisplacement.z,
                        springStretch: simd_length(settings.springDisplacement),
                        springAnchorNDC: SIMD2<Float>(0.7, -0.7),
                        springVisible: (settings.springActive || simd_length(settings.springDisplacement) > 0.001) ? 1 : 0,
                        springRestRadius: 0.06,
                        jitterOffset: .zero,
                        renderResolution: [1, 1],
                        floorPlane: SIMD4<Float>(0, 1, 0, 0),
                        floorCenterRadius: SIMD4<Float>(0, 0, 0, 0),
                        formulaParams: settings.formulaParams,
                        precomputedFractal: precomputedFractal,
                        precomputedLighting: precomputedLighting,
                        precomputedAudio: precomputedAudio,
                        precomputedFog: precomputedFog,
                        colorScheme: settings.colorSchemeParams)
    }

    private static func buildRenderPipeline(device: MTLDevice,
                                            colorPixelFormat: MTLPixelFormat,
                                            depthPixelFormat: MTLPixelFormat,
                                            vertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "screenshotVertexShader") else {
                        throw SetupError.metalLibraryUnavailable
        }

        let constants = MTLFunctionConstantValues()
        let fragmentFunction = try library.makeFunction(name: "fragmentShaderMono", constantValues: constants)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Raymarch Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Full-screen blit pipeline that copies the MetalFX upscaled output to the
    /// drawable. Single-view, no vertex/depth attachments — the vertex shader
    /// generates an oversized triangle from `vertex_id`.
    private static func buildBlitPipeline(device: MTLDevice, colorPixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "macBlitVertex"),
              let fragmentFunction = library.makeFunction(name: "macBlitFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Blit Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Full-screen motion-vector pipeline (Stage B). Reads the offscreen depth
    /// and writes screen-space motion into an `rg16Float` target for the
    /// temporal scaler. No depth attachment.
    private static func buildMotionPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "macBlitVertex"),
              let fragmentFunction = library.makeFunction(name: "macMotionFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ThresholdMac Motion Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = MacTemporalUpscaler.motionFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Radical-inverse Halton sample in `[0, 1)` — sub-pixel jitter sequence for
    /// temporal upscaling (base 2 for X, base 3 for Y).
    private static func halton(_ index: UInt32, base: UInt32) -> Float {
        var result: Float = 0
        var fraction: Float = 1
        var i = index
        while i > 0 {
            fraction /= Float(base)
            result += fraction * Float(i % base)
            i /= base
        }
        return result
    }

    private static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()

        descriptor.attributes[VertexAttribute.position.rawValue].format = .float3
        descriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        descriptor.attributes[VertexAttribute.texcoord.rawValue].format = .float2
        descriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        descriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        descriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = .perVertex

        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        descriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = .perVertex

        return descriptor
    }

    private static func buildMesh(device: MTLDevice, vertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mesh = MDLMesh.newEllipsoid(withRadii: SIMD3<Float>(repeating: 100),
                                        radialSegments: 64,
                                        verticalSegments: 32,
                                        geometryType: .triangles,
                                        inwardNormals: false,
                                        hemisphere: false,
                                        allocator: allocator)

        let modelIODescriptor = MTKModelIOVertexDescriptorFromMetal(vertexDescriptor)
        guard let attributes = modelIODescriptor.attributes as? [MDLVertexAttribute] else {
            throw SetupError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate
        mesh.vertexDescriptor = modelIODescriptor

        return try MTKMesh(mesh: mesh, device: device)
    }
}

#if os(iOS)
import UIKit

/// iPad host for the shared `ThresholdMacRenderer`. Wraps an `MTKView` in a
/// `UIViewRepresentable` and translates touch gestures into the same
/// orbit / pan / zoom input the macOS trackpad path feeds, so the renderer is
/// byte-identical across platforms:
///   • one-finger drag  → orbit
///   • two-finger drag  → pan
///   • pinch            → zoom (mirrors the macOS `magnify` convention)
///
/// The orbit/pan/zoom sign and gain match the validated macOS conventions;
/// if motion feels inverted on device, flip the `dy`/`dx` sign in the gesture
/// handlers — the renderer math is unchanged.
struct ThresholdiOSRenderView: UIViewRepresentable {
    let appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeUIView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.005, green: 0.006, blue: 0.008, alpha: 1.0)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.isMultipleTouchEnabled = true
        view.delegate = context.coordinator
        context.coordinator.attachGestures(to: view)
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.appModel = appModel
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.tearDown()
    }

    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        var appModel: AppModel
        private let inputController = ThresholdMacInputController()
        private var renderer: ThresholdMacRenderer?

        // Incremental gesture tracking. UIPanGestureRecognizer reports cumulative
        // translation; we feed per-callback deltas (points) to match the macOS
        // per-event delta convention.
        private var lastOrbitTranslation: CGPoint = .zero
        private var lastPanTranslation: CGPoint = .zero
        private var lastPinchScale: CGFloat = 1.0
        private weak var twoFingerPan: UIPanGestureRecognizer?
        private weak var pinch: UIPinchGestureRecognizer?

        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
        }

        @MainActor
        func configure(_ view: MTKView) {
            appModel.rendererStartupWarmupComplete = false
            guard let device = view.device,
                  let metalLayer = view.layer as? CAMetalLayer else { return }
            metalLayer.device = device
            metalLayer.pixelFormat = view.colorPixelFormat
            metalLayer.framebufferOnly = true
            metalLayer.drawableSize = view.drawableSize
            renderer = ThresholdMacRenderer(device: device,
                                            appModel: appModel,
                                            inputController: inputController,
                                            metalLayer: metalLayer,
                                            colorPixelFormat: view.colorPixelFormat,
                                            depthPixelFormat: view.depthStencilPixelFormat,
                                            clearColor: view.clearColor)
            renderer?.drawableSizeDidChange(view.drawableSize)
            appModel.rendererStartupWarmupComplete = renderer != nil
        }

        func attachGestures(to view: UIView) {
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
            orbit.minimumNumberOfTouches = 1
            orbit.maximumNumberOfTouches = 1
            orbit.delegate = self

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            twoFingerPan = pan

            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinchGesture.delegate = self
            pinch = pinchGesture

            view.addGestureRecognizer(orbit)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinchGesture)
        }

        func tearDown() {
            inputController.setFocus(false)
            renderer = nil
            Task { @MainActor [appModel] in
                appModel.rendererStartupWarmupComplete = false
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeDidChange(size)
        }

        func draw(in view: MTKView) {
            renderer?.draw(appModel: appModel)
        }

        @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                lastOrbitTranslation = .zero
                inputController.setFocus(true)
            case .changed:
                let delta = SIMD2<Float>(Float(translation.x - lastOrbitTranslation.x),
                                         Float(translation.y - lastOrbitTranslation.y))
                lastOrbitTranslation = translation
                if simd_length_squared(delta) > 0 {
                    inputController.addOrbit(delta: delta)
                }
            default:
                lastOrbitTranslation = .zero
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                lastPanTranslation = .zero
                inputController.setFocus(true)
            case .changed:
                let delta = SIMD2<Float>(Float(translation.x - lastPanTranslation.x),
                                         Float(translation.y - lastPanTranslation.y))
                lastPanTranslation = translation
                if simd_length_squared(delta) > 0 {
                    inputController.addPan(delta: delta)
                }
            default:
                lastPanTranslation = .zero
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                lastPinchScale = gesture.scale
                inputController.setFocus(true)
            case .changed:
                // Mirror the macOS `magnify` convention: pinch-out (scale > 1)
                // feeds a negative zoom delta, which the renderer maps to a
                // larger detail scale (zoom in).
                let delta = Float(gesture.scale - lastPinchScale)
                lastPinchScale = gesture.scale
                if delta != 0 {
                    inputController.addZoom(delta: -delta * 18.0)
                }
            default:
                lastPinchScale = 1.0
            }
        }

        // Allow the two-finger pan and pinch to run together (natural combined
        // pan + zoom); keep the one-finger orbit exclusive.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            let pair: Set<ObjectIdentifier> = [ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)]
            var allowed: Set<ObjectIdentifier> = []
            if let twoFingerPan { allowed.insert(ObjectIdentifier(twoFingerPan)) }
            if let pinch { allowed.insert(ObjectIdentifier(pinch)) }
            return pair.isSubset(of: allowed)
        }
    }
}
#endif
#endif