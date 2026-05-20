import Foundation

extension Renderer {
    func renderLoop() async {
        while true {
            // Yield to the actor's executor once per frame so queued actor jobs
            // (e.g. activateEmbeddedFormula, prewarm handlers) can run between
            // frames. Without this, the infinite render loop monopolises the
            // Renderer actor's serial executor and any external `await
            // renderer.foo()` call deadlocks forever.
            await Task.yield()

            if !appModel.isAppActive {
                // Cooperative sleep so the actor executor can still service
                // queued jobs while the app is inactive.
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            if layerRenderer.state == .invalidated {
                if RENDERER_DEBUG { print("Layer is invalidated") }
                updateImmersiveSpaceStateIfNeeded(.closed)
                return
            } else if layerRenderer.state == .paused {
                updateImmersiveSpaceStateIfNeeded(.inTransition)
                layerRenderer.waitUntilRunning()
                continue
            } else {
                updateImmersiveSpaceStateIfNeeded(.open)

                if shouldCaptureScreenshot {
                    shouldCaptureScreenshot = false
                    // renderScreenshot() is non-blocking: it uses addCompletedHandler
                    // to resume the pending continuation after GPU finishes
                    renderScreenshot()
                }

                if shouldRunProfiler {
                    shouldRunProfiler = false
                    profilePipelineComponents()
                }

                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }

    private func updateImmersiveSpaceStateIfNeeded(_ state: AppModel.ImmersiveSpaceState) {
        guard lastImmersiveSpaceState != state else { return }
        lastImmersiveSpaceState = state
        Task { @MainActor in
            if appModel.immersiveSpaceState != state {
                appModel.immersiveSpaceState = state
            }
        }
    }
}
