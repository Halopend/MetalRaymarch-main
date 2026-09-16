import Cocoa
import Quartz   // QLPreviewingController (QuickLookUI) on macOS

/// Spacebar Quick Look preview for Threshold documents.
///
/// For fractal scenes it installs a live, draggable `InteractiveFractalView`
/// (orbit on drag, scroll to zoom). For everything else — animations, custom
/// formulas, decode failures, or when Metal is unavailable — it falls back to a
/// static image via `ThresholdPreviewRender`.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let container: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }()

    override func loadView() { self.view = container }

    func preparePreviewOfFile(at url: URL) async throws {
        // `NSViewController` is @MainActor, so this method's body — and every
        // helper it calls synchronously — runs on the appex main thread. The
        // file read + JSON decode + the custom-DE pipeline compile ("can take
        // a second or two") must NOT sit there: beachballed previews and
        // watchdog risk on slow hosts. `PreviewPayload.build` is a
        // nonisolated async function, so awaiting it hops to the generic
        // executor; we return to the main actor only to install UI.
        let payload = await PreviewPayload.build(for: url)
        if let scene = payload.scene {
            await MainActor.run { self.installInteractive(scene) }
        } else {
            await MainActor.run { self.installStatic(payload.staticImage) }
        }
    }

    // MARK: Install

    @MainActor private func installInteractive(_ scene: InteractiveScene) {
        guard let fractalView = InteractiveFractalView(settings: scene.settings, formula: scene.formula) else {
            installStatic(nil); return
        }
        embed(fractalView)
    }

    @MainActor private func installStatic(_ cg: CGImage?) {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        if let cg { imageView.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        embed(imageView)
    }

    @MainActor private func embed(_ subview: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Scene → interactive settings

    private struct InteractiveScene: @unchecked Sendable {
        // Immutable after decode; RenderSettings is a lock-protected
        // (@unchecked Sendable) class. The @unchecked conformance covers the
        // EmbeddedFormula struct, which is a plain Codable value.
        let settings: RenderSettings
        let formula: EmbeddedFormula?
    }

    /// Everything `preparePreviewOfFile` needs, fully built OFF the main
    /// actor. `@unchecked Sendable`: both fields are immutable once `build`
    /// returns (CGImage is thread-safe/immutable, per CoreGraphics).
    private final class PreviewPayload: @unchecked Sendable {
        let scene: InteractiveScene?
        let staticImage: CGImage?

        private init(scene: InteractiveScene?, staticImage: CGImage?) {
            self.scene = scene
            self.staticImage = staticImage
        }

        /// nonisolated + async → runs on the generic executor, off the appex
        /// main thread, even when awaited from this @MainActor controller.
        nonisolated static func build(for url: URL) async -> PreviewPayload {
            if let scene = Self.interactiveScene(for: url) {
                // Custom-DE pipeline compile ("can take a second or two").
                _ = HeadlessRenderer.shared?.prewarm(formula: scene.formula)
                return PreviewPayload(scene: scene, staticImage: nil)
            }
            let cg = ThresholdPreviewRender.image(for: url, pixelSize: CGSize(width: 1024, height: 1024))
            return PreviewPayload(scene: nil, staticImage: cg)
        }

        /// Returns a live-renderable scene (built-in OR embedded-DE) for `url`,
        /// else nil (caller shows a static preview). A `.custom` scene missing
        /// its formula is not renderable.
        private static func interactiveScene(for url: URL) -> InteractiveScene? {
            switch ThresholdPreviewRender.DocumentKind(url: url) {
            case .scene, .musicPreset: break
            default: return nil
            }
            guard HeadlessRenderer.shared != nil,
                  let data = try? Data(contentsOf: url),
                  let preset = try? ThresholdPreviewRender.decoder.decode(FractalPreset.self, from: data),
                  !(preset.fractalType == .custom && preset.embeddedFormula == nil) else { return nil }
            let settings = RenderSettings()
            preset.apply(to: settings)
            return InteractiveScene(settings: settings, formula: preset.embeddedFormula)
        }
    }
}
