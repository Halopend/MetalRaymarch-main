//
//  mb3d_import_cli.swift
//  Threshold
//
//  Command-line tool to convert MB3D parameter strings to Threshold presets.
//
//  Compile:
//    swiftc -parse-as-library \
//      MB3DParameterMap.swift MB3DDecoder.swift MB3DToThreshold.swift \
//      mb3d_import_cli.swift -o mb3d_import
//
//  Usage:
//    ./mb3d_import <input.m3p>                    # JSON to stdout
//    ./mb3d_import <input.m3p> -o output.threshmp # writes file
//    echo "Mandelbulb3Dv18{...}" | ./mb3d_import  # reads stdin
//    ./mb3d_import <input.m3p> --raw              # decoded scene dump
//

import Foundation

@main
struct MB3DImportCLI {

    static func printUsage() {
        let usage = """
        MB3D → Threshold Converter

        Usage:
          mb3d_import [options] [input_file]

        Options:
          -o <file>     Write output to file (default: stdout)
          -n <name>     Preset name (default: from title or "MB3D Import")
          --raw         Print decoded scene dump instead of Threshold preset
          --help        Show this help

        Input:
          File path to .m3p, or stdin if no file given.
        """
        print(usage)
    }

    static func readInput(from path: String?) -> String? {
        if let path = path {
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        var input = ""
        while let line = readLine(strippingNewline: false) {
            input += line
        }
        return input.isEmpty ? nil : input
    }

    static func extractMB3DBlock(from text: String) -> String? {
        guard let startRange = text.range(of: "Mandelbulb3D") else { return nil }
        let fromStart = text[startRange.lowerBound...]
        guard fromStart.contains("{"),
              let closeBrace = fromStart.lastIndex(of: "}") else { return nil }
        return String(fromStart[fromStart.startIndex...closeBrace])
    }

    static func main() {
        let args = CommandLine.arguments.dropFirst()
        var inputPath: String? = nil
        var outputPath: String? = nil
        var presetName: String? = nil
        var rawMode = false

        var argIterator = args.makeIterator()
        while let arg = argIterator.next() {
            switch arg {
            case "-o":
                outputPath = argIterator.next()
            case "-n":
                presetName = argIterator.next()
            case "--raw":
                rawMode = true
            case "--help", "-h":
                printUsage()
                return
            default:
                if !arg.hasPrefix("-") {
                    inputPath = arg
                }
            }
        }

        guard let inputText = readInput(from: inputPath) else {
            fputs("Error: No input provided. Use --help for usage.\n", stderr)
            Foundation.exit(1)
        }

        guard let mb3dBlock = extractMB3DBlock(from: inputText) else {
            fputs("Error: No Mandelbulb3D parameter block found.\n", stderr)
            Foundation.exit(1)
        }

        do {
            let scene = try MB3DDecoder.decode(mb3dBlock)

            let output: String
            if rawMode {
                // Print structured dump of decoded scene
                output = rawDump(scene)
            } else {
                output = MB3DToThreshold.exportPresetJSON(
                    scene, name: presetName)
            }

            // Conversion summary to stderr
            let result = MB3DToThreshold.convert(scene)
            fputs("\n✅ Converted MB3D → Threshold\n", stderr)
            fputs("   Fractal type: \(result.fractalType)\n", stderr)
            fputs("   Iterations:   \(result.iterations)\n", stderr)
            fputs("   Detail scale: \(String(format: "%.3f", result.detailScale))\n", stderr)
            let p = result.position
            fputs("   Position:     (\(p[0]), \(p[1]), \(p[2]))\n", stderr)
            if !result.warnings.isEmpty {
                fputs("   ⚠️  Warnings:\n", stderr)
                for w in result.warnings { fputs("      - \(w)\n", stderr) }
            }

            // Write output
            if let outputPath = outputPath {
                try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
                fputs("   Written to: \(outputPath)\n", stderr)
            } else {
                print(output)
            }

        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    // MARK: - Raw Dump

    static func rawDump(_ s: MB3DDecodedScene) -> String {
        var out = [String]()
        out.append("── MB3D Decoded Scene ──")
        out.append("Version: v\(s.version)  MandId: \(s.mandId)")
        if let t = s.title { out.append("Title: \(t)") }
        out.append("Dimensions: \(s.width) × \(s.height)")
        out.append("")
        out.append("Camera:")
        out.append("  Position: (\(s.cameraX), \(s.cameraY), \(s.cameraZ))")
        out.append("  Zoom: \(s.zoom)  FOV: \(s.fov)°")
        out.append("  Z range: \(s.zStart) .. \(s.zEnd)")
        out.append("  4D rot: (\(s.xwRot), \(s.ywRot), \(s.zwRot))")
        out.append("  Rotation matrix:")
        for row in 0..<3 {
            let vals = (0..<3).map { String(format: "%10.6f", s.rotationMatrix[row*3+$0]) }
            out.append("    [\(vals.joined(separator: ", "))]")
        }
        out.append("")
        out.append("Rendering:")
        out.append("  Iterations: \(s.iterations)  MaxIts: \(s.maxIterations)")
        out.append("  Bailout: \(s.bailout)  DEstop: \(s.dEstop)")
        out.append("  StepWidth: \(s.stepWidth)  StepDiv: \(s.raystepDiv)  RayLimiter: \(s.raystepLimiter)")
        if s.isJulia {
            out.append("  Julia: (\(s.juliaX), \(s.juliaY), \(s.juliaZ), \(s.juliaW))")
        }
        out.append("")
        out.append("Formulas (\(s.formulaCount) slots, hybrid=\(s.hybridType)):")
        for f in s.formulaSlots {
            out.append("  [\(f.slotIndex)] ID=\(f.formulaID) \"\(f.formulaName)\"" +
                       "  iters=\(f.iterations)  opts=\(f.optionCount)")
            for (i, v) in f.parameterValues.enumerated() {
                let tag = v == 0 ? "" : " ◀"
                out.append("    dOptionValue[\(i)] = \(v)\(tag)")
            }
        }
        out.append("")
        out.append("Threshold mapping:")
        out.append("  Suggested type: \(s.suggestedThresholdType ?? "none")")
        out.append("")
        out.append("Payload: \(s.payloadByteCount) bytes")
        return out.joined(separator: "\n")
    }
}
