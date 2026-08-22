import Foundation
import CoreGraphics
import ImageIO

// Render regression check for the Quick Look extension.
//
// Compiled + run by Scripts/ql_render_check.sh, which links the SAME source
// closure the appex ships (derived from wire_quicklook.rb) plus a prebuilt
// metallib (via the THRESHOLD_QL_METALLIB env seam in HeadlessRenderer). It
// exercises the REAL extension render path — HeadlessRenderer.render(preset:)
// including the runtime embedded-DE compile — over every bundled FractalPreset
// document (.threshscene AND .threshmp):
//   * ALL must render (non-nil): guards against a closure/compile/GPU
//     regression that would make previews fall back or crash.
//   * the well-framed allowlist must render NON-BLACK: guards against a camera/
//     uniform-packing regression that would silently blank previews.
// Built-in fractals render from the metallib (THRESHOLD_QL_METALLIB, built from
// Shaders.metal); embedded-DE scenes compile from EmbeddedMetalSources (the
// generated snapshot in the closure) — the same dual-source split as the appex.
// So a Shaders.metal edit not mirrored into EmbeddedMetalSources is caught for
// built-in scenes but not embedded ones.
// The allowlist is empirical (mean luminance comfortably > black from the fixed
// camera). Scenes off it may legitimately be black from the fixed start camera
// (authored for gesture navigation), so they're only checked for non-nil.
//
// Exit non-zero on any failure. Usage: render-check <scenesDir>

@main
struct RenderCheck {

    // Scenes that render clearly non-black from the extension's fixed camera.
    static let wellFramed: Set<String> = [
        "The lovely bones", "Pulsing", "Inverted Kleinian", "Orbit Density", "ave",
        "Kettle", "Pseudo Knightyan", "Box", "Metallic Pink", "Pseudo Kleinian",
        "Vampire", "Pool", "Spiky", "Bright Preset", "Wave Rail",
        "Fractal Cartoon", "Blooming blue", "Twilight Mandelbox",
    ]
    static let blackThreshold = 12.0   // mean luminance (0-255)

    static func main() {
        let scenesDir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "Threshold/Examples/Scenes"

        guard let renderer = HeadlessRenderer.shared else {
            FileHandle.standardError.write("FAIL: HeadlessRenderer unavailable (metallib not loaded)\n".data(using: .utf8)!)
            exit(2)
        }

        let fm = FileManager.default
        // Both .threshscene and .threshmp decode as FractalPreset and take the
        // identical live render(preset:) path in the shipping extensions.
        let files = ((try? fm.contentsOfDirectory(atPath: scenesDir)) ?? [])
            .filter { $0.hasSuffix(".threshscene") || $0.hasSuffix(".threshmp") }
            .sorted()
        guard !files.isEmpty else {
            FileHandle.standardError.write("FAIL: no .threshscene files in \(scenesDir)\n".data(using: .utf8)!)
            exit(2)
        }

        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var failures: [String] = []
        var ok = 0

        for f in files {
            let name = (f as NSString).deletingPathExtension
            let url = URL(fileURLWithPath: scenesDir).appendingPathComponent(f)
            guard let data = try? Data(contentsOf: url),
                  let preset = try? dec.decode(FractalPreset.self, from: data) else {
                failures.append("\(name): decode failed"); continue
            }
            guard let cg = renderer.render(preset: preset, pixelSize: CGSize(width: 512, height: 512)) else {
                failures.append("\(name): render returned nil (\(preset.fractalType))"); continue
            }
            // THRESHOLD_QL_PNG_DIR: dump each render as a PNG for visual inspection.
            if let pngDir = ProcessInfo.processInfo.environment["THRESHOLD_QL_PNG_DIR"] {
                let dest = URL(fileURLWithPath: pngDir).appendingPathComponent("\(name).png")
                try? fm.createDirectory(atPath: pngDir, withIntermediateDirectories: true)
                if let cgDest = CGImageDestinationCreateWithURL(dest as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(cgDest, cg, nil)
                    CGImageDestinationFinalize(cgDest)
                }
            }
            let lum = meanLuminance(cg)
            if wellFramed.contains(name) && lum < blackThreshold {
                failures.append("\(name): expected non-black, mean luminance \(String(format: "%.1f", lum)) < \(blackThreshold)")
            } else {
                ok += 1
                print(String(format: "  ok  lum=%6.1f  %@", lum, name))
            }
        }

        print("\nrendered \(files.count) scenes; \(ok) ok; \(failures.count) failure(s)")
        for x in failures { print("  FAIL \(x)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Mean luminance (0-255) of a CGImage, sampled at 64×64 for speed.
    static func meanLuminance(_ cg: CGImage) -> Double {
        let w = 64, h = 64
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
        }
        return sum / Double(w * h)
    }
}
