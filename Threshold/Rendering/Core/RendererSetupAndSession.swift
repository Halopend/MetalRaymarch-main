import ARKit
import Foundation
import Metal

extension Renderer {
    /// Setup residency set for GPU resource pre-validation
    func setupResidencySet() {
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            let descriptor = MTLResidencySetDescriptor()
            descriptor.label = "FractalResidencySet"
            descriptor.initialCapacity = 8

            do {
                residencySet = try device.makeResidencySet(descriptor: descriptor)

                residencySet?.addAllocation(dynamicUniformBuffer)
                residencySet?.addAllocation(cubeMap)

                if let tileBuffer = tileUniformBuffer {
                    residencySet?.addAllocation(tileBuffer)
                }

                residencySet?.commit()
                residencySet?.requestResidency()

                if RENDERER_DEBUG { print("✓ Residency set created with \(residencySet?.allocatedSize ?? 0) bytes") }
            } catch {
                if RENDERER_DEBUG { print("⚠️ Failed to create residency set: \(error)") }
                residencySet = nil
            }
        }
    }

    /// Update residency set when compute output texture changes
    func updateResidencySetForComputeTexture(_ texture: MTLTexture) {
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            guard let set = residencySet else { return }
            set.addAllocation(texture)
            set.commit()
            set.requestResidency()
        }
    }

    /// Setup dynamic render quality management (visionOS 26+)
    func setupDynamicRenderQuality() {
        if #available(visionOS 26.0, *) {
            let settings = appModel.renderSettings
            let manager = DynamicRenderQualityManager(defaultQuality: settings.dynamicRenderQualityTarget)
            manager.minQuality = settings.dynamicRenderQualityMin
            manager.maxQuality = settings.dynamicRenderQualityMax
            manager.isEnabled = settings.dynamicRenderQualityEnabled
            manager.debugLogging = false
            dynamicRenderQualityManager = manager

            if layerRenderer.configuration.isFoveationEnabled {
                if RENDERER_DEBUG {
                    print("✓ Dynamic render quality manager initialized (visionOS 26+)")
                    print("  Target: \(settings.dynamicRenderQualityTarget), Range: \(settings.dynamicRenderQualityMin)-\(settings.dynamicRenderQualityMax)")
                }
            } else {
                if RENDERER_DEBUG { print("ℹ️ Dynamic render quality: Foveation not enabled (quality adjustment disabled)") }
            }
        } else {
            if RENDERER_DEBUG { print("ℹ️ Dynamic render quality: Requires visionOS 26+") }
        }
    }

    func startARSession() async {
        guard WorldTrackingProvider.isSupported else {
            if RENDERER_DEBUG { print("⚠️ World tracking is not supported on this device") }
            return
        }

        if RENDERER_DEBUG { print("ℹ️ Requesting only world sensing (for pose) plus hand tracking; no extra sensors requested.") }
        var authStatus = await arSession.queryAuthorization(for: [.worldSensing, .handTracking])
        if authStatus[.worldSensing] == .notDetermined || authStatus[.handTracking] == .notDetermined {
            if RENDERER_DEBUG { print("🔐 Requesting ARKit world-sensing + hand-tracking authorization") }
            authStatus = await arSession.requestAuthorization(for: [.worldSensing, .handTracking])
        }

        if authStatus[.worldSensing] != .allowed {
            if RENDERER_DEBUG {
                print("⚠️ World sensing not authorized. Status: \(String(describing: authStatus[.worldSensing]))")
                print("   Pose will be limited (rotation only)")
            }
        }

        if authStatus[.handTracking] != .allowed {
            if RENDERER_DEBUG { print("⚠️ Hand tracking not authorized. Status: \(String(describing: authStatus[.handTracking]))") }
        }

        do {
            var providers: [any DataProvider] = [worldTracking]
            if let ht = handTracking, authStatus[.handTracking] == .allowed {
                providers.append(ht)
            }
            try await arSession.run(providers)
            if RENDERER_DEBUG {
                print("✓ ARKit session started with world tracking and hand tracking")
                print("  World tracking state: \(worldTracking.state)")
            }
        } catch {
            if !hasLoggedWorldTrackingWarning {
                if RENDERER_DEBUG { print("⚠️ ARKit session failed: \(error)") }
                hasLoggedWorldTrackingWarning = true
            }
        }
    }
}
