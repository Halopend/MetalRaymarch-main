#if os(macOS)
import AppKit
import Metal
@preconcurrency import MetalKit
import ModelIO
import QuartzCore
import Synchronization
import SwiftUI
import simd

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
}

private protocol ThresholdMacViewportInputDelegate: AnyObject {
    func viewportDidChangeFocus(_ isFocused: Bool)
    func viewportDidOrbit(delta: SIMD2<Float>)
    func viewportDidPan(delta: SIMD2<Float>)
    func viewportDidZoom(delta: Float)
    func viewportDidChangeKey(_ key: ThresholdMacMovementKey, isPressed: Bool)
    func viewportDidChangeShift(_ isPressed: Bool)
    func viewportDidTogglePlayback()
    func viewportDidRequestReset()
}

private final class ThresholdMacInputController: Sendable {
    private struct State {
        var pressedKeys: Set<ThresholdMacMovementKey> = []
        var isShiftPressed: Bool = false
        var orbitDelta: SIMD2<Float> = .zero
        var panDelta: SIMD2<Float> = .zero
        var zoomDelta: Float = 0
        var shouldTogglePlayback = false
        var shouldResetView = false
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

    func consumeFrame() -> ThresholdMacInputFrame {
        state.withLock { current in
            let frame = ThresholdMacInputFrame(
                pressedKeys: current.pressedKeys,
                isShiftPressed: current.isShiftPressed,
                orbitDelta: current.orbitDelta,
                panDelta: current.panDelta,
                zoomDelta: current.zoomDelta,
                shouldTogglePlayback: current.shouldTogglePlayback,
                shouldResetView: current.shouldResetView
            )
            current.orbitDelta = .zero
            current.panDelta = .zero
            current.zoomDelta = 0
            current.shouldTogglePlayback = false
            current.shouldResetView = false
            return frame
        }
    }
}

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
    private var musicReactiveLayerActive: Bool = false
    private var musicReactivePhaseByTarget: [MusicReactiveTarget: Float] = [:]
    private var musicReactiveDecayByTarget: [MusicReactiveTarget: Float] = [:]
    private var musicReactiveDriftByTarget: [MusicReactiveTarget: Float] = [:]
    private var musicLFOPhaseByTarget: [MusicReactiveTarget: Float] = [:]
    private var cachedMusicReactiveFractalType: FractalModelType?
    private var cachedMusicReactiveTripletGains: [String: Float] = [:]
    private var cachedSlotGainLookup: [Int: Float] = [:]
    private var audioOperationsBuffer: [ParameterOperation] = []
    private var parameterOperationFrameIndex: UInt64 = 0

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
        self.clearColor = clearColor
                self.inputController = inputController
                self.uiUpdateCoordinator = UIUpdateCoordinator(appModel: appModel)
                self.parameterUpdateCoordinator = ParameterUpdateCoordinator(appModel: appModel)

        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        let builtPipeline: MTLRenderPipelineState
        let builtMesh: MTKMesh
        do {
            let vertexDescriptor = Self.buildMetalVertexDescriptor()
            builtPipeline = try Self.buildRenderPipeline(device: device, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, vertexDescriptor: vertexDescriptor)
            builtMesh = try Self.buildMesh(device: device, vertexDescriptor: vertexDescriptor)
        } catch {
            print("ThresholdMac renderer setup failed: \(error)")
            return nil
        }
        pipelineState = builtPipeline
        mesh = builtMesh

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
              let drawable = metalLayer.nextDrawable(),
              let renderPassDescriptor = makeRenderPassDescriptor(drawable: drawable) else {
            return
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

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
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

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
        descriptor.storageMode = .private
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
        let hasActiveAudioSources = appModel.audioAnalyzer.isCapturing

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
        let uniforms = makeUniforms(settings: snapshot, elapsedTime: Float(now - startTime), deltaTime: Float(deltaTime))
        let pointer = buffer.contents().bindMemory(to: UniformsArray.self, capacity: 1)
        pointer.pointee.uniforms.0 = uniforms
        pointer.pointee.uniforms.1 = uniforms
    }

    private func applyDesktopInput(appModel: AppModel, settings: RenderSettings, deltaTime: TimeInterval) {
        let input = inputController.consumeFrame()

        if input.shouldResetView {
            resetDesktopView(settings: settings)
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
        let bassSensitivity = settings.bassSensitivity
        let midSensitivity = settings.midSensitivity
        let trebleSensitivity = settings.trebleSensitivity
        let beatSensitivity = settings.beatSensitivity

        settings.bassLevel = min(1.0, analyzer.bassLevel * bassSensitivity)
        settings.midLevel = min(1.0, analyzer.midLevel * midSensitivity)
        settings.trebleLevel = min(1.0, analyzer.trebleLevel * trebleSensitivity)
        settings.beatIntensity = min(1.0, analyzer.peakLevel * 0.7 * beatSensitivity)
        settings.audioLevel = analyzer.level
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

        musicReactiveLayerActive = true

        let bass = settings.bassLevel
        let mid = settings.midLevel
        let treble = settings.trebleLevel
        let beat = settings.beatIntensity
        let globalAmount = settings.fractalAudioAmount
        let beatPunch = settings.fractalBeatPunch

        let bandDrive = bass * 0.55 + mid * 0.30 + treble * 0.15
        let drive = min(1.0, bandDrive * 0.9 + beat * (0.1 + 0.6 * beatPunch))

        audioOperationsBuffer.removeAll(keepingCapacity: true)

        let activeFractalType = settings.fractalType
        let mappings = settings.musicReactiveMappings
        let tripletGains = settings.tripletMusicGains

        if cachedMusicReactiveFractalType != activeFractalType ||
            cachedMusicReactiveTripletGains != tripletGains {
            cachedMusicReactiveFractalType = activeFractalType
            cachedMusicReactiveTripletGains = tripletGains
            cachedSlotGainLookup.removeAll(keepingCapacity: true)

            if !tripletGains.isEmpty {
                let triplets = ParameterNodeRegistry.shared.gestureBindableTriplets(for: activeFractalType)
                let floatParams = MusicReactiveTarget.floatFormulaParams(for: activeFractalType)
                for triplet in triplets {
                    guard let gain = tripletGains[triplet.groupName], gain != 1.0 else { continue }
                    for formulaIndex in [triplet.xFormulaIndex, triplet.yFormulaIndex, triplet.zFormulaIndex] {
                        if let slot = floatParams.firstIndex(where: { $0.index == formulaIndex }) {
                            cachedSlotGainLookup[slot] = gain
                        }
                    }
                }
            }
        }

        let slotGainLookup = cachedSlotGainLookup

        for mapping in mappings where mapping.isEnabled {
            let sourceValue: Float
            switch mapping.source {
            case .composite:
                sourceValue = drive
            case .bass:
                sourceValue = bass
            case .mid:
                sourceValue = mid
            case .treble:
                sourceValue = treble
            case .beat:
                sourceValue = beat
            case .overall:
                sourceValue = settings.audioLevel
            }

            let absAmount = abs(mapping.amount)
            let sign: Float = mapping.amount >= 0 ? 1.0 : -1.0
            let allowed = mapping.target.allowedRange(for: activeFractalType)
            let allowedSpan = allowed.upperBound - allowed.lowerBound
            let maxDeviation = allowedSpan * 0.15 * absAmount * globalAmount

            let delta: Float
            switch mapping.responseCurve {
            case .sinusoidal:
                let phaseSpeed: Float = 2.0 + sourceValue * 4.0
                var phase = musicReactivePhaseByTarget[mapping.target] ?? 0
                phase += phaseSpeed * deltaTime
                phase = phase - floor(phase)
                musicReactivePhaseByTarget[mapping.target] = phase
                delta = sin(phase * 2.0 * .pi) * sourceValue * maxDeviation * sign

            case .pulse:
                let attack = sourceValue * sourceValue
                var decay = musicReactiveDecayByTarget[mapping.target] ?? 0
                decay = max(attack, decay * exp(-6.0 * deltaTime))
                musicReactiveDecayByTarget[mapping.target] = decay
                delta = decay * maxDeviation * sign

            case .drift:
                let target = sourceValue * maxDeviation * sign
                var drifted = musicReactiveDriftByTarget[mapping.target] ?? 0
                let driftRate: Float = 2.0
                drifted += (target - drifted) * min(1.0, deltaTime / driftRate)
                musicReactiveDriftByTarget[mapping.target] = drifted
                delta = drifted

            case .hybrid:
                let combo = max(0.0, min(1.0, mapping.hybridCombo))

                let target = sourceValue * maxDeviation * sign
                var drifted = musicReactiveDriftByTarget[mapping.target] ?? 0
                let driftRate: Float = 2.4
                drifted += (target - drifted) * min(1.0, deltaTime / driftRate)
                musicReactiveDriftByTarget[mapping.target] = drifted

                let vibrationSpeed: Float = 6.0 + sourceValue * 8.0 + combo * 4.0
                var phase = musicReactivePhaseByTarget[mapping.target] ?? 0
                phase += vibrationSpeed * deltaTime
                phase = phase - floor(phase)
                musicReactivePhaseByTarget[mapping.target] = phase

                let vibrationAmplitude = maxDeviation * sourceValue * (0.08 + 0.35 * combo)
                let vibration = sin(phase * 2.0 * .pi) * vibrationAmplitude * sign

                let combined = drifted + vibration
                let limit = maxDeviation * 1.2
                delta = max(-limit, min(limit, combined))
            }

            var lfoOffset: Float = 0
            if mapping.lfo.enabled {
                var phase = musicLFOPhaseByTarget[mapping.target] ?? 0
                phase += mapping.lfo.frequency * deltaTime
                phase = phase - floor(phase)
                musicLFOPhaseByTarget[mapping.target] = phase
                lfoOffset = mapping.lfo.shape.evaluate(phase: phase) * mapping.lfo.amplitude * maxDeviation
            }

            let rawTargetValue = delta + lfoOffset

            guard let targetID = mapping.target.parameterTargetID(for: activeFractalType) else { continue }

            let finalOffset: Float
            if let slot = mapping.target.formulaParamSlot, let gain = slotGainLookup[slot] {
                finalOffset = rawTargetValue * gain
            } else {
                finalOffset = rawTargetValue
            }

            audioOperationsBuffer.append(
                ParameterOperation(
                    targetID: targetID,
                    source: .audio,
                    value: .absolute(finalOffset),
                    frameIndex: parameterOperationFrameIndex,
                    smoothing: ParameterOperationSmoothing(
                        smoothingTime: max(0.02, mapping.smoothingWindow)
                    )
                )
            )
        }

        if !audioOperationsBuffer.isEmpty {
            appModel.parameterPipeline.dispatchAudio(audioOperationsBuffer, settings: settings)
            parameterOperationFrameIndex &+= 1
        }
    }

    private func clearMusicReactiveLayersIfNeeded(appModel: AppModel, settings: RenderSettings) {
        if musicReactiveLayerActive {
            appModel.parameterPipeline.clearMusicLayers(settings: settings)
        }
        musicReactiveLayerActive = false
        musicReactivePhaseByTarget.removeAll()
        musicReactiveDecayByTarget.removeAll()
        musicReactiveDriftByTarget.removeAll()
        musicLFOPhaseByTarget.removeAll()
    }

    private func resetDesktopView(settings: RenderSettings) {
        if settings.isAnimationPlaying {
            settings.clearAnimationManualOffsets()
        } else {
            settings.position = Self.defaultTargetPosition
            settings.targetPosition = Self.defaultTargetPosition
        }
        settings.resetDetailTransform()
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
        let projection = Self.makePerspectiveProjection(fovyRadians: Float.pi / 3, aspect: aspect, nearZ: 0.01, farZ: 500.0)
        let viewMatrix = matrix4x4_translation(0, 0, -3.0)
        let modelView = viewMatrix * modelMatrix
        let inverseModelView = modelView.inverse

        let precomputedFractal = Self.makePrecomputedFractal(from: settings)
        let precomputedLighting = Self.makePrecomputedLighting(time: elapsedTime,
                                                               lightingMode: settings.lightingMode,
                                                               audioLevel: settings.audioLevel,
                                                               bassLevel: settings.bassLevel,
                                                               midLevel: settings.midLevel,
                                                               trebleLevel: settings.trebleLevel,
                                                               beatIntensity: settings.beatIntensity)
        let precomputedAudio = Self.makePrecomputedAudio(from: settings)
        var precomputedFog = Self.makePrecomputedFog(from: settings)
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

        return Uniforms(projectionMatrix: projection,
                        modelViewMatrix: modelView,
                        inverseModelViewMatrix: inverseModelView,
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
                        _pad_uniforms: [0, 0],
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

    private static func makePerspectiveProjection(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
        let yScale = 1.0 / tan(fovyRadians * 0.5)
        let xScale = yScale / aspect
        let zScale = farZ / (nearZ - farZ)
        let wzScale = nearZ * farZ / (nearZ - farZ)

        return matrix_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, wzScale, 0)
        ))
    }

    private static func makePrecomputedFractal(from settings: RenderSettingsSnapshot) -> PrecomputedFractalParams {
        let inverseMinRadius = 1.0 / settings.minDistance
        var scale = SIMD4<Float>(repeating: settings.fractalScale * inverseMinRadius)
        scale.w = abs(scale.w)

        let absScaleMinusOne = abs(settings.fractalScale - 1.0)
        let absScalePower = pow(max(abs(settings.fractalScale), 1e-6), Float(1 - settings.fractalIterations))
        let sphereRadiusSquared = settings.sphereRadius * settings.sphereRadius

        return PrecomputedFractalParams(scale: scale,
                                        absScalem1: absScaleMinusOne,
                                        absScalePow: absScalePower,
                                        invSphereRadiusSq: 1.0 / sphereRadiusSquared,
                                        sphereRadiusSq: sphereRadiusSquared)
    }

    private static func makePrecomputedLighting(time: Float,
                                                lightingMode: LightingMode,
                                                audioLevel: Float,
                                                bassLevel: Float,
                                                midLevel: Float,
                                                trebleLevel: Float,
                                                beatIntensity: Float) -> PrecomputedLighting {
        let animatedTime = time * 0.01 + 15.00
        let spotLightPosition: SIMD3<Float>
        let lightIntensity: Float

        switch lightingMode {
        case .staticLight:
            spotLightPosition = SIMD3<Float>(2.0, 1.5, 2.0)
            lightIntensity = 1.0
        case .audioReactive:
            let basePosition = SIMD3<Float>(1.5, 1.0, 1.5)
            let bassAmplitude = max(audioLevel, bassLevel) * 2.0
            let trebleSpeed = 2.0 + trebleLevel * 4.0
            let audioOffset = SIMD3<Float>(sin(animatedTime * trebleSpeed) * bassAmplitude,
                                           midLevel * 2.0,
                                           cos(animatedTime * trebleSpeed) * bassAmplitude)
            spotLightPosition = basePosition + audioOffset
            lightIntensity = 0.5 + audioLevel * 1.0 + bassLevel * 0.5
        case .visualizer:
            let beatJump = beatIntensity * 3.0
            let orbitSpeed = 1.5 + midLevel * 3.0
            spotLightPosition = SIMD3<Float>(
                sin(animatedTime * orbitSpeed) * (2.0 + bassLevel * 2.0) + beatJump * sin(animatedTime * 8.0),
                1.0 + trebleLevel * 2.0 + beatIntensity * 1.5,
                cos(animatedTime * orbitSpeed) * (2.0 + bassLevel * 2.0) + beatJump * cos(animatedTime * 8.0)
            )
            lightIntensity = 0.3 + bassLevel * 1.5 + beatIntensity * 0.5
        case .animated:
            let pathTime = animatedTime + 0.03
            let path = SIMD3<Float>(-0.78 + 3.0 * sin(2.14 * pathTime),
                                    0.05 + 2.5 * sin(0.942 * pathTime + 1.3),
                                    0.05 + 3.5 * cos(3.594 * pathTime))
            let offset = SIMD3<Float>(sin(animatedTime * 18.4),
                                      cos(animatedTime * 17.98),
                                      sin(animatedTime * 22.53)) * 0.2
            spotLightPosition = path + offset
            lightIntensity = 0.9 + sin(animatedTime * 1.5) * 0.15
        }

        return PrecomputedLighting(spotLightPosition: spotLightPosition, lightIntensity: lightIntensity)
    }

    private static func makePrecomputedAudio(from settings: RenderSettingsSnapshot) -> PrecomputedAudio {
        let maxBand = max(settings.bassLevel, max(settings.midLevel, settings.trebleLevel))
        let weightedEnergy = settings.bassLevel * 0.6 + settings.midLevel * 0.3 + settings.trebleLevel * 0.1
        return PrecomputedAudio(bands: SIMD4<Float>(settings.bassLevel, settings.midLevel, settings.trebleLevel, settings.beatIntensity),
                                energy: SIMD2<Float>(maxBand, weightedEnergy),
                                pad: .zero)
    }

    private static func makePrecomputedFog(from settings: RenderSettingsSnapshot) -> PrecomputedFog {
        let fogIntensity = settings.fogEnabled ? settings.fogIntensity : 0.0
        let inverseFog = fogIntensity > 1e-6 ? 1.0 / fogIntensity : 0.0
        return PrecomputedFog(fog: SIMD4<Float>(fogIntensity, inverseFog, 0.0, 0.0),
                              color: SIMD4<Float>(settings.fogColor.x, settings.fogColor.y, settings.fogColor.z, 0.0))
    }
}
#endif