import Cocoa
import Quartz   // QLPreviewingController (QuickLookUI) on macOS

/// Spacebar Quick Look preview for Threshold documents. Renders the fractal
/// live and displays it; falls back to an info card via `ThresholdPreviewRender`.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let imageView: NSImageView = {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Render at a generous fixed size; Quick Look scales the view to fit.
        let side: CGFloat = 1024
        let pixelSize = CGSize(width: side, height: side)
        let cg = ThresholdPreviewRender.image(for: url, pixelSize: pixelSize)
        await MainActor.run {
            if let cg {
                self.imageView.image = NSImage(cgImage: cg,
                                               size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}
