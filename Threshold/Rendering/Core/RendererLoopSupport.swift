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
                    let screenshotData = renderScreenshot()
                    if RENDERER_DEBUG {
                        if screenshotData != nil {
                            print("📷 Screenshot captured (\(screenshotData!.count) bytes)")
                        } else {
                            print("⚠️ Screenshot capture FAILED")
                        }
                    }
                    pendingScreenshotContinuation?.resume(returning: screenshotData)
                    pendingScreenshotContinuation = nil
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
