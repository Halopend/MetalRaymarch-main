import ARKit
import Foundation
import Metal

extension Renderer {
    /// Setup residency set for GPU resource pre-validation
    func setupResidencySet() {
        #if targetEnvironment(simulator)
        // MTLResidencySet is unsupported on the Simulator. With Metal API
        // Validation on (the default for Debug builds launched from Xcode),
        // `makeResidencySet` doesn't return an error — the validation layer
        // calls MTLReportFailure → __assert_rtn → abort(), which the do/catch
        // below cannot intercept (it's a C-level abort, not a Swift throw).
        // Residency sets are a pure perf optimization; every use is guarded
        // with `if let set = residencySet`, so skipping here is safe and only
        // affects the Simulator. Real devices keep the full path.
        residencySet = nil
        return
        #else
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            let descriptor = MTLResidencySetDescriptor()
            descriptor.label = "FractalResidencySet"
            descriptor.initialCapacity = 8

            do {
                residencySet = try device.makeResidencySet(descriptor: descriptor)

                residencySet?.addAllocation(dynamicUniformBuffer)

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
        #endif
    }

    /// Batch-add multiple textures to the residency set with a single commit + requestResidency.
    func updateResidencySetForComputeTextures(_ textures: [MTLTexture]) {
        if #available(visionOS 2.0, iOS 18.0, macOS 15.0, *) {
            guard let set = residencySet, !textures.isEmpty else { return }
            for texture in textures {
                set.addAllocation(texture)
            }
            set.commit()
            set.requestResidency()
        }
    }

    func startARSession() async {
        guard WorldTrackingProvider.isSupported else {
            print("⚠️ World tracking is not supported on this device – hand gestures unavailable")
            await MainActor.run { appModel.gestureStatus = "World tracking not supported" }
            return
        }

        if RENDERER_DEBUG { print("ℹ️ Requesting only world sensing (for pose) plus hand tracking; no extra sensors requested.") }
        var authStatus = await arSession.queryAuthorization(for: [.worldSensing, .handTracking])
        if authStatus[.worldSensing] == .notDetermined || authStatus[.handTracking] == .notDetermined {
            print("🔐 Requesting ARKit world-sensing + hand-tracking authorization")
            authStatus = await arSession.requestAuthorization(for: [.worldSensing, .handTracking])
        }

        if authStatus[.worldSensing] != .allowed {
            print("⚠️ World sensing not authorized. Status: \(String(describing: authStatus[.worldSensing]))")
            print("   Pose will be limited (rotation only)")
        }

        let handTrackingAllowed = authStatus[.handTracking] == .allowed

        if !handTrackingAllowed {
            print("⚠️ Hand tracking NOT authorized. Status: \(String(describing: authStatus[.handTracking]))")
            print("   → Go to Settings > Privacy & Security > Hand & Body Tracking to enable")
            await MainActor.run {
                appModel.gestureStatus = "Hand tracking not authorized – check Settings"
            }
        } else {
            print("✓ Hand tracking authorized")
        }

        do {
            var providers: [any DataProvider] = [worldTracking]
            if let ht = handTracking, handTrackingAllowed {
                providers.append(ht)
                print("✓ Hand tracking provider added to ARKit session")
            } else if !handTrackingAllowed {
                print("⚠️ Hand tracking provider NOT added (authorization denied)")
            }
            // Environment Scrunch: scene reconstruction supplies the scanned
            // surroundings as mesh anchors (needs world sensing, same grant as
            // pose above).
            if let sr = sceneReconstruction, authStatus[.worldSensing] == .allowed {
                providers.append(sr)
                print("✓ Scene reconstruction provider added (Environment Scrunch source)")
            }
            try await arSession.run(providers)
            print("✓ ARKit session started with \(providers.count) providers")
            startEnvironmentMeshTasks()
            if RENDERER_DEBUG {
                print("  World tracking state: \(worldTracking.state)")
            }
        } catch {
            if !hasLoggedWorldTrackingWarning {
                print("⚠️ ARKit session failed: \(error)")
                await MainActor.run {
                    appModel.gestureStatus = "ARKit session failed: \(error.localizedDescription)"
                }
                hasLoggedWorldTrackingWarning = true
            }
        }
    }

    // MARK: - Environment Scrunch (scene-reconstruction source)

    /// Consumes the scene-reconstruction anchor stream into `environmentMeshes`
    /// (world-space triangle soup per anchor) and runs a throttled bake loop
    /// that folds every anchor into a fresh EnvironmentSDFGrid whenever the
    /// cache is dirty. Bakes are full rebakes on a utility task (~hundreds of
    /// ms for a room at 64³) published atomically via the `environmentSDF`
    /// Mutex — a frame that captured the previous grid keeps a valid buffer.
    func startEnvironmentMeshTasks() {
        guard let sr = sceneReconstruction, meshUpdatesTask == nil else { return }
        meshUpdatesTask = Task.detached(priority: .utility) { [weak self] in
            for await update in sr.anchorUpdates {
                guard !Task.isCancelled, let self else { return }
                let anchor = update.anchor
                switch update.event {
                case .removed:
                    self.environmentMeshes.withLock { $0[anchor.id] = nil }
                case .added, .updated:
                    let tris = Renderer.worldTriangles(from: anchor)
                    self.environmentMeshes.withLock { $0[anchor.id] = tris }
                }
                self.environmentMeshesDirty.withLock { $0 = true }
            }
        }
        guard envBakeTask == nil else { return }
        let bakeDevice = device
        envBakeTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let dirty = self.environmentMeshesDirty.withLock { d -> Bool in
                    let was = d; d = false; return was
                }
                guard dirty else { continue }
                let tris = self.environmentMeshes.withLock { Array($0.values) }.flatMap { $0 }
                guard tris.count >= 3 else { continue }
                // Center the 8×4×8 m grid on the scanned geometry's footprint;
                // floor margin comes from the fixed -0.5 m origin offset.
                var lo = tris[0], hi = tris[0]
                for t in tris { lo = simd_min(lo, t); hi = simd_max(hi, t) }
                let center = (lo + hi) * 0.5
                let origin = SIMD3<Float>(center.x - 4.0, -0.5, center.z - 4.0)
                if let grid = EnvironmentSDFGrid.bake(device: bakeDevice,
                                                      triangles: tris,
                                                      originWorld: origin) {
                    self.environmentSDF.withLock { $0 = grid }
                }
            }
        }
    }

    /// Extracts a mesh anchor's triangles as world-space vertex triples.
    nonisolated static func worldTriangles(from anchor: MeshAnchor) -> [SIMD3<Float>] {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        guard vertices.format == .float3 else { return [] }
        let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
        func vertex(_ i: Int) -> SIMD3<Float> {
            let ptr = vBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
            return SIMD3<Float>(ptr[0], ptr[1], ptr[2])
        }
        let toWorld = anchor.originFromAnchorTransform
        func world(_ i: Int) -> SIMD3<Float> {
            let p = vertex(i)
            let w = toWorld * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD3<Float>(w.x, w.y, w.z)
        }
        let iBase = faces.buffer.contents()
        let indexCount = faces.count * 3
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(indexCount)
        if faces.bytesPerIndex == 4 {
            let idx = iBase.assumingMemoryBound(to: UInt32.self)
            for i in 0..<indexCount { out.append(world(Int(idx[i]))) }
        } else if faces.bytesPerIndex == 2 {
            let idx = iBase.assumingMemoryBound(to: UInt16.self)
            for i in 0..<indexCount { out.append(world(Int(idx[i]))) }
        }
        return out
    }
}
