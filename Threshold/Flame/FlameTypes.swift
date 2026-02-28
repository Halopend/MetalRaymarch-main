import Foundation
import simd

struct FlameTransform: Sendable {
    struct Affine: Sendable {
        var a: Float
        var b: Float
        var c: Float
        var d: Float
        var e: Float
        var f: Float

        static let identity = Affine(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
    }

    var weight: Float
    var color: Float
    var affine: Affine
    var variations: [String: Float]
}

struct FlameDocument: Sendable {
    var name: String
    var width: Int
    var height: Int
    var gamma: Float
    var brightness: Float
    var transforms: [FlameTransform]
}

enum FlameParseError: Error, LocalizedError {
    case invalidXML
    case noFlameNode
    case noTransforms

    var errorDescription: String? {
        switch self {
        case .invalidXML:
            return "Invalid .flam3 XML file."
        case .noFlameNode:
            return "No <flame> node found in this file."
        case .noTransforms:
            return "No <xform> transforms found in this flame."
        }
    }
}
