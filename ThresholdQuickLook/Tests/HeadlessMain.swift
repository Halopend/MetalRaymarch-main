import Foundation
import CoreGraphics
import ImageIO
import Darwin

private let usage = """
usage: Scripts/metal-raymarch-headless <scene.threshscene> [options]
  --out <path.png>       PNG output (default metal-raymarch-out.png)
  --json <path|->        JSON result destination (default stdout)
  --no-image             compute metrics without writing a PNG
  --width <pixels>       exact output width, 16...4096 (default 512)
  --height <pixels>      exact output height, 16...4096 (default 512)
  --time <seconds>       fixed shader animation time (default 0)
  --timeout <seconds>    hard render timeout; exits 124 (default 30)
  --quiet                suppress human-readable progress on stderr
  --help                 show this help

The JSON object is the stable automation interface. Pixel hashes are FNV-1a
over canonical RGBA8 output and are deterministic for the same GPU/toolchain.
"""

private enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

private struct Options: Sendable {
    var scenePath = ""
    var outPath = "metal-raymarch-out.png"
    var jsonPath = "-"
    var writeImage = true
    var width = 512
    var height = 512
    var elapsedTime: Float = 0
    var timeout = 30.0
    var quiet = false

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var index = 0
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw CLIError.message("missing value for \(flag)")
            }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--out": result.outPath = try value(for: argument)
            case "--json": result.jsonPath = try value(for: argument)
            case "--no-image": result.writeImage = false
            case "--width":
                guard let parsed = Int(try value(for: argument)) else {
                    throw CLIError.message("--width expects an integer")
                }
                result.width = parsed
            case "--height":
                guard let parsed = Int(try value(for: argument)) else {
                    throw CLIError.message("--height expects an integer")
                }
                result.height = parsed
            case "--time":
                guard let parsed = Float(try value(for: argument)), parsed.isFinite else {
                    throw CLIError.message("--time expects a finite number")
                }
                result.elapsedTime = parsed
            case "--timeout":
                guard let parsed = Double(try value(for: argument)), parsed > 0,
                      parsed.isFinite else {
                    throw CLIError.message("--timeout expects a positive finite number")
                }
                result.timeout = parsed
            case "--quiet": result.quiet = true
            case "--help", "-h": print(usage); exit(0)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.message("unknown option \(argument)")
                }
                guard result.scenePath.isEmpty else {
                    throw CLIError.message("only one scene may be rendered per invocation")
                }
                result.scenePath = argument
            }
            index += 1
        }
        guard !result.scenePath.isEmpty else {
            throw CLIError.message("a .threshscene or .threshmp path is required")
        }
        guard (16...4096).contains(result.width), (16...4096).contains(result.height) else {
            throw CLIError.message("width and height must be in 16...4096")
        }
        return result
    }
}

private struct SuccessReport: Codable {
    let ok: Bool
    let renderer: String
    let scenePath: String
    let sceneName: String
    let fractalType: String
    let width: Int
    let height: Int
    let elapsedTime: Float
    let outputPath: String?
    let pixelHash: String
    let meanLuminance: Double
    let nonBlackFraction: Double
    let gpuMilliseconds: Double
    let wallMilliseconds: Double
}

private struct FailureReport: Codable {
    let ok: Bool
    let renderer: String
    let scenePath: String?
    let error: String
}

private enum RenderOutcome {
    case success(HeadlessRenderResult)
    case failure(String)
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RenderOutcome?

    func store(_ newValue: RenderOutcome) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func load() -> RenderOutcome? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@main
private struct MetalRaymarchHeadless {
    static func main() {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("metal-raymarch-headless: \(error)\n\(usage)\n".utf8))
            exit(2)
        }

        let sceneURL = URL(fileURLWithPath: options.scenePath).standardizedFileURL
        let preset: FractalPreset
        do {
            let data = try Data(contentsOf: sceneURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            preset = try decoder.decode(FractalPreset.self, from: data)
        } catch {
            emitFailure("scene decode failed: \(error)", options: options, exitCode: 3)
        }

        if !options.quiet {
            FileHandle.standardError.write(Data(
                "rendering \(preset.name) at \(options.width)x\(options.height)\n".utf8))
        }

        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        let wallStart = ProcessInfo.processInfo.systemUptime
        // Legacy scene setup still contains a few plain `print` diagnostics.
        // Keep stdout exclusively machine-readable by routing those messages
        // to stderr for the duration of renderer initialization + execution.
        let savedStdout = redirectStdoutToStderr()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let renderer = HeadlessRenderer.shared else {
                box.store(.failure("Metal device, shader library, or pipeline unavailable"))
                semaphore.signal()
                return
            }
            guard let result = renderer.renderForAutomation(
                preset: preset, width: options.width, height: options.height,
                elapsedTime: options.elapsedTime) else {
                box.store(.failure("renderer returned no image"))
                semaphore.signal()
                return
            }
            box.store(.success(result))
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + options.timeout)
        restoreStdout(savedStdout)
        guard waitResult == .success else {
            emitFailure("render timed out after \(options.timeout) seconds",
                        options: options, exitCode: 124)
        }
        let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - wallStart) * 1_000
        guard case .success(let result)? = box.load() else {
            let message: String
            if case .failure(let reason)? = box.load() { message = reason }
            else { message = "renderer completed without a result" }
            emitFailure(message, options: options, exitCode: 4)
        }
        guard let rgba = canonicalRGBA(result.image) else {
            emitFailure("could not normalize rendered pixels", options: options, exitCode: 4)
        }

        var outputPath: String?
        if options.writeImage {
            let url = URL(fileURLWithPath: options.outPath).standardizedFileURL
            do {
                try writePNG(result.image, to: url)
                outputPath = url.path
            } catch {
                emitFailure("PNG write failed: \(error)", options: options, exitCode: 5)
            }
        }

        let metrics = pixelMetrics(rgba)
        let report = SuccessReport(
            ok: true, renderer: "metal-raymarch-headless-v1",
            scenePath: sceneURL.path, sceneName: preset.name,
            fractalType: String(describing: preset.fractalType),
            width: options.width, height: options.height,
            elapsedTime: options.elapsedTime, outputPath: outputPath,
            pixelHash: fnv1a64(rgba), meanLuminance: metrics.mean,
            nonBlackFraction: metrics.nonBlackFraction,
            gpuMilliseconds: result.gpuMilliseconds,
            wallMilliseconds: wallMilliseconds)
        do {
            try emit(report, path: options.jsonPath)
        } catch {
            FileHandle.standardError.write(Data("JSON write failed: \(error)\n".utf8))
            exit(6)
        }
    }

    private static func emitFailure(_ message: String, options: Options,
                                    exitCode: Int32) -> Never {
        let report = FailureReport(ok: false, renderer: "metal-raymarch-headless-v1",
                                   scenePath: options.scenePath.isEmpty ? nil : options.scenePath,
                                   error: message)
        try? emit(report, path: options.jsonPath)
        FileHandle.standardError.write(Data("metal-raymarch-headless: \(message)\n".utf8))
        exit(exitCode)
    }

    private static func emit<T: Encodable>(_ value: T, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        if path == "-" {
            FileHandle.standardOutput.write(data)
        } else {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private static func redirectStdoutToStderr() -> Int32? {
        fflush(nil)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { return nil }
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(saved)
            return nil
        }
        return saved
    }

    private static func restoreStdout(_ saved: Int32?) {
        guard let saved else { return }
        fflush(nil)
        _ = dup2(saved, STDOUT_FILENO)
        close(saved)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CLIError.message("could not create image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.message("ImageIO could not finalize the PNG")
        }
    }

    private static func canonicalRGBA(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let made = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: info.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return made ? bytes : nil
    }

    private static func pixelMetrics(_ rgba: [UInt8]) -> (mean: Double, nonBlackFraction: Double) {
        var luminanceSum = 0.0
        var nonBlack = 0
        let pixels = rgba.count / 4
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let luminance = 0.2126 * Double(rgba[index])
                + 0.7152 * Double(rgba[index + 1])
                + 0.0722 * Double(rgba[index + 2])
            luminanceSum += luminance
            if luminance > 3 { nonBlack += 1 }
        }
        return (luminanceSum / Double(max(pixels, 1)),
                Double(nonBlack) / Double(max(pixels, 1)))
    }

    private static func fnv1a64(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }
}
