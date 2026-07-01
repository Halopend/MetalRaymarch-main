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
        // Build the interactive scene settings (decode + GPU param setup) and, for
        // embedded-DE scenes, compile the custom pipeline here — off the main
        // actor — so the view's first frame is instant. Then install UI.
        if let scene = Self.interactiveScene(for: url) {
            HeadlessRenderer.shared?.prewarm(formula: scene.formula)
            await MainActor.run { self.installInteractive(scene) }
            return
        }
        let cg = ThresholdPreviewRender.image(for: url, pixelSize: CGSize(width: 1024, height: 1024))
        await MainActor.run { self.installStatic(cg) }
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

    private struct InteractiveScene {
        let settings: RenderSettings
        let formula: EmbeddedFormula?
    }

    /// Returns a live-renderable scene (built-in OR embedded-DE) for `url`, else
    /// nil (caller shows a static preview). A `.custom` scene missing its formula
    /// is not renderable.
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
