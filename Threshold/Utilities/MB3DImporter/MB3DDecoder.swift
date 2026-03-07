//
//  MB3DDecoder.swift
//  Threshold
//
//  Decodes Mandelbulb3D parameter strings into structured data.
//
//  MB3D text format (v16+):
//    Header line: "Mandelbulb3Dv18{"
//    Payload: Custom base-64 encoded binary, 4 chars → 3 bytes
//      - First 280 groups (1120 chars) = TMandHeader10 (840 bytes)
//      - Remaining groups = THeaderCustomAddon (hybrid formula slots)
//    Closing: "}"
//    Optional: "{Titel: scene_name}"
//
//  Encoding uses Delphi ThreeBytesTo4Chars / FourCharsTo3Bytes:
//    6-bit values (0-63), 4 chars = 24 bits = 3 bytes, LSB first.
//    Character mapping (from MB3D DivUtils.pas):
//      value 0-11  → ASCII 46-57  (. / 0 1 2 3 4 5 6 7 8 9)
//      value 12-37 → ASCII 65-90  (A B C ... Z)
//      value 38-63 → ASCII 97-122 (a b c ... z)
//

import Foundation

// MARK: - Decoded Scene

/// Complete decoded representation of a Mandelbulb3D parameter string.
struct MB3DDecodedScene {
    // Format
    let version: Int        // from header line (16, 17, 18)
    let title: String?      // from optional {Titel: ...} block
    let mandId: Int         // TMandHeader10.MandId — internal version tag

    // Image dimensions
    let width: Int
    let height: Int

    // Camera (fractal centre in MB3D world space)
    let cameraX: Double     // dXmid
    let cameraY: Double     // dYmid
    let cameraZ: Double     // dZmid
    let zoom: Double        // dZoom
    let fov: Double         // dFOVy (degrees)
    let zStart: Double      // dZstart — near clip
    let zEnd: Double        // dZend  — far clip

    // 4D rotation
    let xwRot: Double       // dXWrot
    let ywRot: Double       // dYWrot
    let zwRot: Double       // dZWrot

    // View rotation matrix (3×3, 9 doubles, row-major hVGrads)
    let rotationMatrix: [Double]

    // Rendering
    let iterations: Int       // Iterations header field
    let maxIterations: Int    // iMaxIts
    let bailout: Double       // RStop
    let dEstop: Float         // sDEstop — DE stop distance
    let raystepDiv: Float     // mZstepDiv — ray-step divisor
    let stepWidth: Double     // dStepWidth
    let raystepLimiter: Float // sRaystepLimiter

    // Julia mode
    let juliaX: Double
    let juliaY: Double
    let juliaZ: Double
    let juliaW: Double
    var isJulia: Bool { juliaX != 0 || juliaY != 0 || juliaZ != 0 || juliaW != 0 }

    // Formula slots (from THeaderCustomAddon)
    let formulaSlots: [MB3DFormulaSlot]
    let hybridType: Int       // 0 = alternating, 1 = interpolated, 2 = DE-combinate
    let formulaCount: Int     // active slot count

    // Diagnostics
    let payloadByteCount: Int

    /// The formula slot most likely to be the "primary" fractal.
    /// In hybrids, modifier slots often have 1 iteration while the main fractal
    /// has many more.  Pick highest iteration count; break ties by slot index.
    var primaryFormulaSlot: MB3DFormulaSlot? {
        formulaSlots.max(by: {
            $0.iterations != $1.iterations
                ? $0.iterations < $1.iterations
                : $0.slotIndex > $1.slotIndex
        })
    }

    /// Best-match Threshold fractal type from primary formula
    var suggestedThresholdType: String? {
        guard let primary = primaryFormulaSlot else { return nil }
        return MB3DFormulaDatabase.thresholdType(
            for: primary.formulaID, name: primary.formulaName)
    }
}

/// A single formula slot from THeaderCustomAddon.
struct MB3DFormulaSlot {
    let slotIndex: Int
    let formulaID: Int             // iFnr
    let formulaName: String        // CustomFname or builtin lookup
    let iterations: Int            // iItCount
    let optionCount: Int           // iOptionCount
    let parameterValues: [Double]  // dOptionValue[0..15] — 16 doubles
}

// MARK: - MB3D Base64 Codec

/// MB3D custom 6-bit encoding. NOT standard Base64 or Base91.
/// Matches Delphi ThreeBytesTo4Chars / FourCharsTo3Bytes exactly.
enum MB3DBase64 {

    /// Convert ASCII byte to 6-bit value (0-63), or nil if invalid.
    /// Delphi logic: if c > 96 → c-59; elif c > 64 → c-53; else c-46
    @inline(__always)
    private static func charValue(_ c: UInt8) -> UInt8? {
        let v = Int(c)
        if v >= 97 && v <= 122 { return UInt8(v - 59) }   // a-z → 38-63
        if v >= 65 && v <= 90  { return UInt8(v - 53) }   // A-Z → 12-37
        if v >= 46 && v <= 57  { return UInt8(v - 46) }   // ./0-9 → 0-11
        return nil
    }

    /// Decode MB3D payload text → raw bytes.  4 chars → 3 bytes (24-bit LE groups).
    static func decode(_ string: String) -> Data {
        // Filter to valid payload characters only
        let valid: [UInt8] = Array(string.utf8).filter { charValue($0) != nil }

        var output = Data()
        output.reserveCapacity(valid.count * 3 / 4)

        var i = 0
        while i + 4 <= valid.count {
            // Exact Delphi FourCharsTo3Bytes: accumulate 4 × 6-bit values → 24-bit int
            var acc: UInt32 = 0
            for j in 0..<4 {
                acc += UInt32(charValue(valid[i + j])!) << (j * 6)
            }
            output.append(UInt8( acc        & 0xFF))
            output.append(UInt8((acc >>  8) & 0xFF))
            output.append(UInt8((acc >> 16) & 0xFF))
            i += 4
        }

        // Trailing 1-3 chars → 1-2 bytes
        if i < valid.count {
            var acc: UInt32 = 0
            let rem = valid.count - i
            for j in 0..<rem {
                acc += UInt32(charValue(valid[i + j])!) << (j * 6)
            }
            for b in 0..<(rem * 6 / 8) {
                output.append(UInt8((acc >> (b * 8)) & 0xFF))
            }
        }

        return output
    }
}

// MARK: - Binary Reader

private struct BinaryReader {
    let data: Data
    var offset: Int = 0

    var remaining: Int { data.count - offset }

    mutating func seek(to position: Int) { offset = position }

    mutating func readUInt8() -> UInt8? {
        guard offset < data.count else { return nil }
        let v = data[data.startIndex + offset]
        offset += 1
        return v
    }

    mutating func readInt32() -> Int32? {
        guard offset + 4 <= data.count else { return nil }
        let s = data.startIndex + offset
        let v = data[s..<s+4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        offset += 4
        return Int32(littleEndian: v)
    }

    mutating func readFloat32() -> Float? {
        guard offset + 4 <= data.count else { return nil }
        let s = data.startIndex + offset
        let v = data[s..<s+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset += 4
        return Float(bitPattern: UInt32(littleEndian: v))
    }

    mutating func readFloat64() -> Double? {
        guard offset + 8 <= data.count else { return nil }
        let s = data.startIndex + offset
        let v = data[s..<s+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return Double(bitPattern: UInt64(littleEndian: v))
    }

    /// Read a null-terminated ASCII string of up to `maxLen` bytes.
    mutating func readASCII(_ maxLen: Int) -> String {
        var bytes: [UInt8] = []
        for _ in 0..<maxLen {
            guard let b = readUInt8() else { break }
            if b == 0 { break }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - Main Decoder

enum MB3DDecoder {

    // ── TMandHeader10 byte offsets (Delphi packed record, 840 bytes total) ──
    // Verified from thargor6/mb3d TypeDefinitions.pas
    private enum H {
        static let mandId      = 0     // Integer (4)
        static let width       = 4     // Integer (4)
        static let height      = 8     // Integer (4)
        static let iterations  = 12    // Integer (4)
        // 16: iOptions(Word 2), 18: bNewOptions(1), 19: bColorOnIt(1)
        static let dZstart     = 20    // Double (8)
        static let dZend       = 28    // Double (8)
        static let dXmid       = 36    // Double (8)
        static let dYmid       = 44    // Double (8)
        static let dZmid       = 52    // Double (8)
        static let dXWrot      = 60    // Double (8)
        static let dYWrot      = 68    // Double (8)
        static let dZWrot      = 76    // Double (8)
        static let dZoom       = 84    // Double (8)
        static let rStop       = 92    // Double (8) = bailout
        // 100: iReflectsCalcTime(4), 104: sFmixPow(4)
        static let dFOVy       = 108   // Double (8)
        // 116..153: various settings
        static let dStepWidth  = 154   // Double (8)
        // 162..176: various
        static let sDEstop     = 177   // Single (4)
        // 181: byte
        static let mZstepDiv   = 182   // Single (4) — ray-step divisor
        // 186..190: padding / other
        static let dJx         = 191   // Double (8) — Julia
        static let dJy         = 199   // Double (8)
        static let dJz         = 207   // Double (8)
        static let dJw         = 215   // Double (8)
        // 223..241: miscellaneous
        static let sRaystepLimiter = 242 // Single (4)
        static let hVGrads     = 246   // TMatrix3 (9 × Double = 72) — rotation
        // 318..413: more fields
        static let iMaxIts     = 414   // Integer (4)
        // 418..431: miscellaneous
        static let light       = 432   // TLightingParas9 (408 bytes) → ends at 840
        static let size        = 840
    }

    // ── THeaderCustomAddon (starts at byte 840) ──
    private enum A {
        static let bHCAversion = 0     // Byte
        static let bOptions1   = 1     // Byte — hybrid type flag
        // 2: bOptions2, 3: bOptions3
        static let iFCount     = 4     // Byte — active formula count
        // 5: bHybOpt1, 6-7: bHybOpt2 (Word)
        static let formulas    = 8     // THAformula[0..5]
    }

    // ── THAformula (188 bytes each) ──
    private enum F {
        static let iItCount     = 0    // Integer (4)
        static let iFnr         = 4    // Integer (4) — formula ID
        static let iOptionCount = 8    // Integer (4)
        static let customFname  = 12   // char[32] — null-terminated ASCII name
        static let byOptionType = 44   // Byte[16]
        static let dOptionValue = 60   // Double[16] (128 bytes) — formula parameters
        static let size         = 188
    }

    enum DecodeError: Error, CustomStringConvertible {
        case invalidHeader(String)
        case decodeFailed
        case payloadTooShort(Int)

        var description: String {
            switch self {
            case .invalidHeader(let h): return "Invalid MB3D header: \(h)"
            case .decodeFailed:         return "Decode produced empty data"
            case .payloadTooShort(let n):
                return "Payload too short: \(n) bytes (need ≥ \(H.size))"
            }
        }
    }

    // MARK: Public API

    /// Parse a Mandelbulb3D parameter string into an MB3DDecodedScene.
    static func decode(_ parameterString: String) throws -> MB3DDecodedScene {

        // ── 1. Locate delimiters ──
        guard let openBrace = parameterString.firstIndex(of: "{") else {
            throw DecodeError.invalidHeader("No opening brace")
        }
        let headerPart = parameterString[parameterString.startIndex..<openBrace]
        guard headerPart.contains("Mandelbulb3D") else {
            throw DecodeError.invalidHeader(String(headerPart.prefix(40)))
        }

        let version: Int
        if let vRange = headerPart.range(of: #"v(\d+)"#, options: .regularExpression) {
            version = Int(headerPart[vRange].dropFirst()) ?? 18
        } else {
            version = 18
        }

        guard let closeBrace = parameterString[
            parameterString.index(after: openBrace)...
        ].firstIndex(of: "}") else {
            throw DecodeError.invalidHeader("No closing brace")
        }

        let payloadText = String(
            parameterString[parameterString.index(after: openBrace)..<closeBrace])

        // Optional title: {Titel: name}
        var title: String? = nil
        let after = parameterString[parameterString.index(after: closeBrace)...]
        if let ts = after.range(of: "{Titel:"),
           let te = after[ts.upperBound...].firstIndex(of: "}") {
            title = String(after[ts.upperBound..<te])
                .trimmingCharacters(in: .whitespaces)
        }

        // ── 2. Decode binary payload ──
        let raw = MB3DBase64.decode(payloadText)
        guard !raw.isEmpty else { throw DecodeError.decodeFailed }
        guard raw.count >= H.size else { throw DecodeError.payloadTooShort(raw.count) }

        var r = BinaryReader(data: raw)

        // ── 3. TMandHeader10 (bytes 0-839) ──
        r.seek(to: H.mandId);      let mandId = Int(r.readInt32() ?? 0)
        r.seek(to: H.width);       let width  = Int(r.readInt32() ?? 0)
        r.seek(to: H.height);      let height = Int(r.readInt32() ?? 0)
        r.seek(to: H.iterations);  let iters  = Int(r.readInt32() ?? 10)

        r.seek(to: H.dZstart);     let zStart = r.readFloat64() ?? 0
        r.seek(to: H.dZend);       let zEnd   = r.readFloat64() ?? 100

        r.seek(to: H.dXmid);       let camX = r.readFloat64() ?? 0
        r.seek(to: H.dYmid);       let camY = r.readFloat64() ?? 0
        r.seek(to: H.dZmid);       let camZ = r.readFloat64() ?? 0

        r.seek(to: H.dXWrot);      let xwRot = r.readFloat64() ?? 0
        r.seek(to: H.dYWrot);      let ywRot = r.readFloat64() ?? 0
        r.seek(to: H.dZWrot);      let zwRot = r.readFloat64() ?? 0

        r.seek(to: H.dZoom);       let zoom    = r.readFloat64() ?? 1
        r.seek(to: H.rStop);       let bailout = r.readFloat64() ?? 100
        r.seek(to: H.dFOVy);       let fov     = r.readFloat64() ?? 45

        r.seek(to: H.dStepWidth);  let stepWidth = r.readFloat64() ?? 0
        r.seek(to: H.sDEstop);     let dEstop    = r.readFloat32() ?? 0.001
        r.seek(to: H.mZstepDiv);   let rsDiv     = r.readFloat32() ?? 1.0

        r.seek(to: H.dJx);         let jx = r.readFloat64() ?? 0
        r.seek(to: H.dJy);         let jy = r.readFloat64() ?? 0
        r.seek(to: H.dJz);         let jz = r.readFloat64() ?? 0
        r.seek(to: H.dJw);         let jw = r.readFloat64() ?? 0

        r.seek(to: H.sRaystepLimiter); let rsLim = r.readFloat32() ?? 1.0

        // Rotation matrix (3×3 = 9 doubles)
        r.seek(to: H.hVGrads)
        var rotMat = [Double]()
        for _ in 0..<9 { rotMat.append(r.readFloat64() ?? 0) }

        r.seek(to: H.iMaxIts);     let maxIts = Int(r.readInt32() ?? 10)

        // ── 4. THeaderCustomAddon (bytes 840+) ──
        var slots: [MB3DFormulaSlot] = []
        var hybridType = 0
        var formulaCount = 0

        let ab = H.size  // addon base = 840
        if raw.count > ab + A.formulas {
            r.seek(to: ab + A.bOptions1)
            hybridType = Int(r.readUInt8() ?? 0)

            r.seek(to: ab + A.iFCount)
            formulaCount = Int(r.readUInt8() ?? 0)

            for slot in 0..<min(max(formulaCount, 1), 6) {
                let base = ab + A.formulas + slot * F.size
                guard raw.count >= base + F.size else { break }

                r.seek(to: base + F.iItCount)
                let itCount = Int(r.readInt32() ?? 0)

                r.seek(to: base + F.iFnr)
                let fnr = Int(r.readInt32() ?? 0)
                guard fnr > 0 else { continue }  // empty slot

                r.seek(to: base + F.iOptionCount)
                let optCount = Int(r.readInt32() ?? 0)

                r.seek(to: base + F.customFname)
                let customName = r.readASCII(32)
                let name = customName.isEmpty
                    ? MB3DFormulaDatabase.builtinName(for: fnr)
                    : customName

                r.seek(to: base + F.dOptionValue)
                var vals = [Double]()
                for _ in 0..<16 { vals.append(r.readFloat64() ?? 0) }

                slots.append(MB3DFormulaSlot(
                    slotIndex: slot,
                    formulaID: fnr,
                    formulaName: name,
                    iterations: itCount,
                    optionCount: optCount,
                    parameterValues: vals
                ))
            }
        }

        // ── 5. Diagnostic output ──
        print("ℹ️  MB3D v\(version) — \(raw.count) bytes decoded (MandId=\(mandId))")
        print("   Dimensions: \(width)×\(height)  Iters: \(iters)  MaxIts: \(maxIts)")
        print("   Camera: (\(camX), \(camY), \(camZ))  Zoom: \(zoom)  FOV: \(fov)")
        print("   Bailout: \(bailout)  DEstop: \(dEstop)  StepDiv: \(rsDiv)")
        if jx != 0 || jy != 0 || jz != 0 || jw != 0 {
            print("   Julia: (\(jx), \(jy), \(jz), \(jw))")
        }
        print("   Rotation matrix: \(rotMat.map { String(format: "%.4f", $0) })")
        print("   Formulas: \(formulaCount) slot(s), hybrid type=\(hybridType)")
        for s in slots {
            print("     [\(s.slotIndex)] ID=\(s.formulaID) \"\(s.formulaName)\" " +
                  "iters=\(s.iterations) opts=\(s.optionCount)")
            for (i, v) in s.parameterValues.enumerated() where v != 0 {
                print("       param[\(i)] = \(v)")
            }
        }

        return MB3DDecodedScene(
            version: version, title: title, mandId: mandId,
            width: width, height: height,
            cameraX: camX, cameraY: camY, cameraZ: camZ,
            zoom: zoom, fov: fov, zStart: zStart, zEnd: zEnd,
            xwRot: xwRot, ywRot: ywRot, zwRot: zwRot,
            rotationMatrix: rotMat,
            iterations: iters, maxIterations: maxIts,
            bailout: bailout, dEstop: dEstop,
            raystepDiv: rsDiv, stepWidth: stepWidth,
            raystepLimiter: rsLim,
            juliaX: jx, juliaY: jy, juliaZ: jz, juliaW: jw,
            formulaSlots: slots, hybridType: hybridType,
            formulaCount: formulaCount,
            payloadByteCount: raw.count
        )
    }
}
