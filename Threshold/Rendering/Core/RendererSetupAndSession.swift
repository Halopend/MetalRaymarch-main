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
            if let rt = roomTracking, authStatus[.worldSensing] == .allowed {
                providers.append(rt)
                print("✓ Room tracking provider added (automatic space bounds)")
            }
            try await arSession.run(providers)
            guard !Task.isCancelled else { return }
            print("✓ ARKit session started with \(providers.count) providers")
            startRoomBoundsTask()
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

    // MARK: - Environment understanding

    /// Tracks ARKit's current room and publishes a smoothed, oriented rectangular
    /// fit for Bound to Space. RoomAnchor isolates the room the wearer occupies,
    /// avoiding adjacent-space leakage through doors that a global mesh AABB
    /// would otherwise include.
    func startRoomBoundsTask() {
        guard let rt = roomTracking, roomUpdatesTask == nil else { return }
        roomUpdatesTask = Task.detached(priority: .utility) { [weak self] in
            func publishCurrentRoom(unavailableAnchorID: UUID? = nil) {
                guard !Task.isCancelled, let self else { return }
                guard let room = rt.currentRoomAnchor, room.isCurrentRoom else {
                    // Do not discard a good fit merely because the provider is
                    // between updates. Clear only when ARKit explicitly removes
                    // or declassifies the anchor that supplied the active box.
                    guard let unavailableAnchorID else { return }
                    let removed = self.trackedRoomBounds.withLock { state -> Bool in
                        guard state?.anchorID == unavailableAnchorID else { return false }
                        state = nil
                        return true
                    }
                    if removed { Task { await self.roomBoundsDidChange() } }
                    return
                }

                let triangles = Renderer.worldTriangles(
                    from: room.geometry,
                    originFromGeometryTransform: room.originFromAnchorTransform
                )
                guard let candidate = EnvironmentRoomBounds.estimateRectangularRoom(
                    triangles: triangles,
                    trimFraction: 0.0025
                ) else { return }

                let changed = self.trackedRoomBounds.withLock { state -> Bool in
                    guard let previous = state, previous.anchorID == room.id else {
                        state = Renderer.TrackedRoomBoundsState(anchorID: room.id, bounds: candidate)
                        return true
                    }
                    guard previous.bounds.isMeaningfullyDifferent(from: candidate) else { return false }
                    state = Renderer.TrackedRoomBoundsState(
                        anchorID: room.id,
                        bounds: previous.bounds.blended(toward: candidate, alpha: 0.28)
                    )
                    return true
                }
                if changed { Task { await self.roomBoundsDidChange() } }
            }

            // Handle a room that was established before this consumer began,
            // then keep it current as ARKit refines or changes room anchors.
            publishCurrentRoom()
            for await update in rt.anchorUpdates {
                guard !Task.isCancelled else { return }
                let unavailableAnchorID: UUID?
                switch update.event {
                case .removed:
                    unavailableAnchorID = update.anchor.id
                case .added, .updated:
                    unavailableAnchorID = update.anchor.isCurrentRoom ? nil : update.anchor.id
                }
                publishCurrentRoom(unavailableAnchorID: unavailableAnchorID)
            }
        }
    }

    /// A live containment boundary changes the distance field independently of
    /// RenderSettings. Invalidate both temporal paths so an old room cannot
    /// warm-start a ray beyond a newly moved wall.
    func roomBoundsDidChange() {
        warmStartGate.invalidate()
        computeWarmStartGate.invalidate()
    }

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
                    self.meshRoomBounds.withLock { $0 = nil }
                } else {
                    // Fit a lower-confidence rectangular fallback from scene
                    // reconstruction. RoomTracking wins whenever it has a
                    // current room, but this makes automatic sizing useful while
                    // that provider is still converging or unavailable.
                    if let candidate = EnvironmentRoomBounds.estimateRectangularRoom(
                        triangles: tris,
                        trimFraction: 0.01
                    ) {
                        let changed = self.meshRoomBounds.withLock { current -> Bool in
                            guard let previous = current else {
                                current = candidate
                                return true
                            }
                            guard previous.isMeaningfullyDifferent(from: candidate) else { return false }
                            current = previous.blended(toward: candidate, alpha: 0.18)
                            return true
                        }
                        // The scene fit is only the active boundary while Room
                        // Tracking has not established the current room. Avoid
                        // invalidating temporal history for background fallback
                        // refinements that cannot affect the rendered box.
                        if changed, self.trackedRoomBounds.withLock({ $0 == nil }) {
                            Task { await self.roomBoundsDidChange() }
                        }
                    }

                    // Size the grid around the actual scan plus its useful SDF
                    // band. The former fixed 8×4×8 m volume silently cropped
                    // larger rooms and rooms whose floor/ceiling were offset
                    // from the AR session origin.
                    var lo = tris[0], hi = tris[0]
                    for t in tris { lo = simd_min(lo, t); hi = simd_max(hi, t) }
                    let center = (lo + hi) * 0.5
                    let bandPadding = SIMD3<Float>(repeating: 1.25 * 2)
                    let desiredSize = (hi - lo) + bandPadding
                    let gridSize = simd_min(
                        simd_max(desiredSize, SIMD3<Float>(8.0, 4.0, 8.0)),
                        SIMD3<Float>(20.0, 10.0, 20.0)
                    )
                    let origin = center - gridSize * 0.5
                    if let grid = EnvironmentSDFGrid.bake(device: bakeDevice,
                                                          triangles: tris,
                                                          originWorld: origin,
                                                          sizeWorld: gridSize) {
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
        worldTriangles(
            from: anchor.geometry,
            originFromGeometryTransform: anchor.originFromAnchorTransform
        )
    }

    /// Shared extractor for MeshAnchor and RoomAnchor geometry.
    nonisolated static func worldTriangles(
        from geometry: MeshAnchor.Geometry,
        originFromGeometryTransform toWorld: matrix_float4x4
    ) -> [SIMD3<Float>] {
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
