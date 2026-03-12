import Foundation

extension Renderer {
    func renderLoop() {
        while true {
            
            if !appModel.isAppActive {
                Thread.sleep(forTimeInterval: 0.05)
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
