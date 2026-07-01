import QuickLookThumbnailing
import CoreGraphics

/// Finder / Quick Look thumbnail provider for Threshold documents.
/// Renders the fractal live (via `ThresholdPreviewRender`) and draws it
/// aspect-fit into the requested thumbnail context.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let contextSize = request.maximumSize          // points
        let pixelSize = CGSize(width: contextSize.width * request.scale,
                               height: contextSize.height * request.scale)

        guard let image = ThresholdPreviewRender.image(for: request.fileURL, pixelSize: pixelSize) else {
            handler(nil, nil)
            return
        }

        let reply = QLThumbnailReply(contextSize: contextSize) { (ctx: CGContext) -> Bool in
            let fitted = ThumbnailProvider.aspectFit(imageSize: CGSize(width: image.width, height: image.height),
                                                     into: contextSize)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: fitted)
            return true
        }
        handler(reply, nil)
    }

    /// Centered aspect-fit rect for `imageSize` inside `bounds`.
    static func aspectFit(imageSize: CGSize, into bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (bounds.width - w) * 0.5, y: (bounds.height - h) * 0.5, width: w, height: h)
    }
}
