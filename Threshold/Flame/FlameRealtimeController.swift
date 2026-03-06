import Foundation
import CoreGraphics

@MainActor
final class FlameRealtimeController: ObservableObject {
    enum Quality: String, CaseIterable, Identifiable {
        case fast = "Fast"
        case balanced = "Balanced"
        case high = "High"

        var id: String { rawValue }

        var width: Int {
            switch self {
            case .fast: return 420
            case .balanced: return 560
            case .high: return 720
            }
        }

        var iterations: Int {
            switch self {
            case .fast: return 120_000
            case .balanced: return 220_000
            case .high: return 360_000
            }
        }

        var targetFrameTimeNs: UInt64 {
            switch self {
            case .fast: return 33_000_000  // ~30 FPS target
            case .balanced: return 41_000_000  // ~24 FPS target
            case .high: return 55_000_000  // ~18 FPS target
            }
        }
    }

    @Published var frameImage: CGImage?
    @Published var isRunning = false
    @Published var statusText: String = ""
    @Published var measuredFPS: Double = 0
    @Published var quality: Quality = .balanced
    @Published var autoOrbit = true
    @Published var orbitSpeed: Float = 0.75
    @Published var yawOffset: Float = 0
    @Published var pitchOffset: Float = 0
    @Published var depthScale: Float = 0.78
    @Published var perspective: Float = 0.30

    private var loopTask: Task<Void, Never>?
    private var phase: Float = 0

    func applyOrbitDrag(deltaX: Float, deltaY: Float) {
        yawOffset += deltaX
        pitchOffset = max(-1.0, min(1.0, pitchOffset + deltaY))
    }

    func applyPinchScale(_ scale: Float) {
        // Pinch in/out adjusts depth and perspective subtly for a volumetric feel.
        let clampedScale = max(0.7, min(1.3, scale))
        depthScale = max(0.2, min(1.8, depthScale * clampedScale))
        perspective = max(0.08, min(0.70, perspective / clampedScale))
    }

    func resetCamera() {
        yawOffset = 0
        pitchOffset = 0
        depthScale = 0.78
        perspective = 0.30
        orbitSpeed = 0.75
    }

    func start(flameProvider: @escaping @MainActor () -> FlameDocument?) {
        guard loopTask == nil else { return }
        isRunning = true
        statusText = "Realtime 3D active"

        loopTask = Task { [weak self] in
            guard let self else { return }
            var lastFrameTime = CFAbsoluteTimeGetCurrent()

            while !Task.isCancelled {
                guard self.isRunning else { break }

                let flame = await MainActor.run { flameProvider() }
                guard let flame else {
                    self.statusText = "No flame loaded"
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continue
                }

                let q = self.quality
                let frameStart = CFAbsoluteTimeGetCurrent()
                let autoOrbitEnabled = self.autoOrbit
                let speed = self.orbitSpeed
                let yawOffset = self.yawOffset
                let pitchOffset = self.pitchOffset
                let depthScale = self.depthScale
                let perspective = self.perspective
                let phase = self.phase

                let baseYaw = autoOrbitEnabled ? phase : 0
                let basePitch = autoOrbitEnabled ? 0.22 * sin(phase * 0.63) : 0
                let yaw = baseYaw + yawOffset
                let pitch = max(-1.2, min(1.2, basePitch + pitchOffset))

                let output = await Task.detached(priority: .userInitiated) {
                    FlameRenderer.renderPseudo3DFrame(
                        flame: flame,
                        width: q.width,
                        height: q.width,
                        iterations: q.iterations,
                        burnIn: max(2_000, q.iterations / 24),
                        phase: phase,
                        yaw: yaw,
                        pitch: pitch,
                        depthScale: depthScale,
                        perspective: perspective
                    )
                }.value

                if Task.isCancelled || !self.isRunning { break }

                if let output {
                    self.frameImage = output.image
                    let now = CFAbsoluteTimeGetCurrent()
                    let dt = max(1e-4, now - lastFrameTime)
                    let instant = 1.0 / dt
                    self.measuredFPS = self.measuredFPS == 0 ? instant : (self.measuredFPS * 0.85 + instant * 0.15)
                    self.statusText = "Realtime 3D • \(output.sampleCount) points • \(Int(self.measuredFPS)) FPS"
                    lastFrameTime = now
                } else {
                    self.statusText = "Realtime 3D produced no frame"
                }

                if autoOrbitEnabled {
                    self.phase += max(0.005, min(0.12, 0.055 * speed))
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - frameStart
                let target = Double(q.targetFrameTimeNs) / 1_000_000_000.0
                let delay = max(0, target - elapsed)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
    }

    func restart(flameProvider: @escaping @MainActor () -> FlameDocument?) {
        stop()
        start(flameProvider: flameProvider)
    }
}
