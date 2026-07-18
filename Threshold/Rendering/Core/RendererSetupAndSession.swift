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

                // Keep only stable, renderer-lifetime buffers in this set.
                // Resizeable compute/MetalFX textures are already referenced by
                // their encoders; adding every replacement here without removing
                // the old allocation pins all prior resolution buckets and grows
                // the Vision Pro working set until jetsam.
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

    func startARSession() async {
        guard WorldTrackingProvider.isSupported else {
            print("⚠️ World tracking is not supported on this device – hand gestures unavailable")
            await MainActor.run { appModel.gestureStatus = "World tracking not supported" }
            return
        }

        if RENDERER_DEBUG { print("ℹ️ Requesting only world sensing (for pose) plus hand tracking; no extra sensors requested.") }
        var authStatus = await arSession.queryAuthorization(for: [.worldSensing, .handTracking])
        guard !Task.isCancelled else { return }
        if authStatus[.worldSensing] == .notDetermined || authStatus[.handTracking] == .notDetermined {
            print("🔐 Requesting ARKit world-sensing + hand-tracking authorization")
            authStatus = await arSession.requestAuthorization(for: [.worldSensing, .handTracking])
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            print("✓ ARKit session started with \(providers.count) providers")
            startEnvironmentMeshTasks()
            if RENDERER_DEBUG {
                print("  World tracking state: \(worldTracking.state)")
            }
        } catch {
            // Closing the immersive space cancels this startup task. That is a
            // normal lifecycle transition, not an authorization/session error.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
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
                guard let self else { return }
                let dirty = self.environmentMeshesDirty.withLock { d -> Bool in
                    let was = d; d = false; return was
                }
                guard dirty else {
                    // Poll quickly until the first anchors arrive so selecting
                    // Environment containment does not appear inert for two
                    // seconds at launch. Full rebakes remain throttled below.
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let tris = self.environmentMeshes.withLock { Array($0.values) }.flatMap { $0 }
                if tris.count < 3 {
                    // Do not keep clipping against a room that ARKit has removed
                    // (session reset, tracking relocation, or anchor teardown).
                    self.environmentSDF.withLock { $0 = nil }
                } else {
                    // Center the 8×4×8 m grid on the scanned geometry. ARKit's
                    // world origin is session-relative and is not guaranteed to
                    // put the floor at y=0; a fixed y=-0.5 grid can therefore
                    // miss most of a room when tracking starts near head height.
                    var lo = tris[0], hi = tris[0]
                    for t in tris { lo = simd_min(lo, t); hi = simd_max(hi, t) }
                    let center = (lo + hi) * 0.5
                    let origin = center - SIMD3<Float>(4.0, 2.0, 4.0)
                    if let grid = EnvironmentSDFGrid.bake(device: bakeDevice,
                                                          triangles: tris,
                                                          originWorld: origin) {
                        self.environmentSDF.withLock { $0 = grid }
                    }
                }
                // Coalesce the continuous scene-reconstruction update stream.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Extracts a mesh anchor's triangles as world-space vertex triples.
    nonisolated static func worldTriangles(from anchor: MeshAnchor) -> [SIMD3<Float>] {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        let indicesPerFace = faces.primitive.indexCount
        guard vertices.format == .float3,
              vertices.stride >= MemoryLayout<Float>.stride * 3,
              vertices.offset >= 0,
              vertices.offset <= vertices.buffer.length,
              indicesPerFace == 3,
              faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4
        else { return [] }

        let (indexCount, indexCountOverflow) = faces.count.multipliedReportingOverflow(by: indicesPerFace)
        let (indexBytes, indexBytesOverflow) = indexCount.multipliedReportingOverflow(by: faces.bytesPerIndex)
        guard !indexCountOverflow, !indexBytesOverflow,
              indexBytes <= faces.buffer.length else { return [] }

        let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
        func vertex(_ i: Int) -> SIMD3<Float>? {
            guard i >= 0, i < vertices.count else { return nil }
            let (relativeOffset, multiplyOverflow) = i.multipliedReportingOverflow(by: vertices.stride)
            let (absoluteOffset, addOverflow) = vertices.offset.addingReportingOverflow(relativeOffset)
            guard !multiplyOverflow, !addOverflow,
                  absoluteOffset >= 0,
                  absoluteOffset <= vertices.buffer.length - MemoryLayout<Float>.stride * 3
            else { return nil }
            let ptr = vBase.advanced(by: relativeOffset).assumingMemoryBound(to: Float.self)
            let p = SIMD3<Float>(ptr[0], ptr[1], ptr[2])
            return p.x.isFinite && p.y.isFinite && p.z.isFinite ? p : nil
        }
        let toWorld = anchor.originFromAnchorTransform
        func world(_ i: Int) -> SIMD3<Float>? {
            guard let p = vertex(i) else { return nil }
            let w = toWorld * SIMD4<Float>(p.x, p.y, p.z, 1)
            let result = SIMD3<Float>(w.x, w.y, w.z)
            return result.x.isFinite && result.y.isFinite && result.z.isFinite
                ? result
                : nil
        }
        let iBase = faces.buffer.contents()
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(indexCount)

        func index(at position: Int) -> Int {
            if faces.bytesPerIndex == 4 {
                return Int(iBase.assumingMemoryBound(to: UInt32.self)[position])
            }
            return Int(iBase.assumingMemoryBound(to: UInt16.self)[position])
        }

        for face in 0..<faces.count {
            let base = face * indicesPerFace
            guard let a = world(index(at: base)),
                  let b = world(index(at: base + 1)),
                  let c = world(index(at: base + 2))
            else { continue }
            let areaSquared = simd_length_squared(simd_cross(b - a, c - a))
            guard areaSquared.isFinite, areaSquared > 1e-12 else { continue }
            out.append(a)
            out.append(b)
            out.append(c)
        }
        return out
    }
}
