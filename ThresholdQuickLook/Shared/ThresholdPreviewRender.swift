import Foundation
import CoreGraphics
import ImageIO
#if canImport(AppKit)
import AppKit
#endif

/// Shared entry point for both Quick Look extensions (thumbnail + preview).
///
/// Dispatches a Threshold document URL to a live GPU render of the fractal it
/// describes, with graceful fallbacks so a preview is never blank:
///   * `.threshscene` / `.threshmp`  → decode `FractalPreset`, render live.
///   * `.threshanim` / `.threshanimv`→ info card (live keyframe render = M3).
///   * `.threshfx`                   → info card (embedded-formula render = M3).
/// Fallback order for scenes: live render → embedded `thumbnailData` PNG →
/// branded info card drawn with Core Graphics.
enum ThresholdPreviewRender {

    /// Best-effort CGImage for `url`, sized to fit within `pixelSize` (device
    /// pixels). Never throws — returns an image or nil.
    static func image(for url: URL, pixelSize: CGSize) -> CGImage? {
        switch DocumentKind(url: url) {
        case .scene, .musicPreset:
            return renderScene(url: url, pixelSize: pixelSize)
        case .animation, .musicAnimation:
            return animationCard(url: url, pixelSize: pixelSize)
        case .formula:
            return formulaCard(url: url, pixelSize: pixelSize)
        case .unknown:
            return infoCard(title: url.deletingPathExtension().lastPathComponent,
                            subtitle: "Threshold document", pixelSize: pixelSize)
        }
    }

    // MARK: - Scene / music preset (FractalPreset, live render)

    private static func renderScene(url: URL, pixelSize: CGSize) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let preset = try? decoder.decode(FractalPreset.self, from: data) else {
            return infoCard(title: url.deletingPathExtension().lastPathComponent,
                            subtitle: "Threshold Scene", pixelSize: pixelSize)
        }
        if let cg = HeadlessRenderer.shared?.render(preset: preset, pixelSize: pixelSize) {
            return cg
        }
        // Custom-formula scenes (embedded Metal, M3) & any render miss fall back
        // to the baked thumbnail, then a card.
        if let baked = bakedThumbnail(from: preset) { return baked }
        let name = preset.name.isEmpty ? url.deletingPathExtension().lastPathComponent : preset.name
        return infoCard(title: name, subtitle: "Threshold Scene", pixelSize: pixelSize)
    }

    // MARK: - Animation / formula info cards (minimal local decoders)

    private static func animationCard(url: URL, pixelSize: CGSize) -> CGImage? {
        let meta = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AnimationMeta.self, from: $0) }
        let title = meta?.name ?? url.deletingPathExtension().lastPathComponent
        let n = meta?.keyframes?.count ?? 0
        return infoCard(title: title, subtitle: "Animation · \(n) keyframe\(n == 1 ? "" : "s")", pixelSize: pixelSize)
    }

    private static func formulaCard(url: URL, pixelSize: CGSize) -> CGImage? {
        let meta = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(FormulaMeta.self, from: $0) }
        let title = meta?.formula?.name ?? url.deletingPathExtension().lastPathComponent
        let author = meta?.formula?.author.map { "by \($0)" } ?? "Custom Formula"
        return infoCard(title: title, subtitle: author, pixelSize: pixelSize)
    }

    private struct AnimationMeta: Decodable {
        let name: String?
        let keyframes: [Empty]?
        struct Empty: Decodable {}
    }
    private struct FormulaMeta: Decodable {
        let formula: Inner?
        struct Inner: Decodable { let name: String?; let author: String? }
    }

    // MARK: - Fallbacks

    private static func bakedThumbnail(from preset: FractalPreset) -> CGImage? {
        guard let data = preset.thumbnailData,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Branded indigo→violet card with the document name, so previews degrade
    /// gracefully instead of going blank.
    static func infoCard(title: String, subtitle: String, pixelSize: CGSize) -> CGImage? {
        let w = max(64, Int(pixelSize.width.rounded()))
        let h = max(64, Int(pixelSize.height.rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.05, green: 0.03, blue: 0.12, alpha: 1),
                      CGColor(red: 0.18, green: 0.06, blue: 0.30, alpha: 1)] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])
        }
        #if canImport(AppKit)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let inset = CGFloat(w) * 0.08
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(11, CGFloat(w) * 0.10), weight: .semibold),
            .foregroundColor: NSColor.white]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(8, CGFloat(w) * 0.05), weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.65)]
        (title as NSString).draw(at: CGPoint(x: inset, y: CGFloat(h) * 0.42), withAttributes: titleAttrs)
        (subtitle as NSString).draw(at: CGPoint(x: inset, y: CGFloat(h) * 0.30), withAttributes: subAttrs)
        NSGraphicsContext.restoreGraphicsState()
        #endif
        return ctx.makeImage()
    }

    // MARK: - Support

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum DocumentKind {
        case scene, musicPreset, animation, musicAnimation, formula, unknown
        init(url: URL) {
            switch url.pathExtension.lowercased() {
            case "threshscene": self = .scene
            case "threshmp":    self = .musicPreset
            case "threshanim":  self = .animation
            case "threshanimv": self = .musicAnimation
            case "threshfx":    self = .formula
            default:            self = .unknown
            }
        }
    }
}
