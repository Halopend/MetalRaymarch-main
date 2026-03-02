import Foundation

final class FlameXMLParser: NSObject, XMLParserDelegate {
    private var parsedFlame: FlameDocument?
    private var currentTransforms: [FlameTransform] = []
    private var foundFlameNode = false

    // Multi-flame parsing state
    private var allFlames: [FlameDocument] = []
    private var parseAllMode = false

    /// Parse a single flame from data (returns the first `<flame>` found).
    func parse(data: Data) throws -> FlameDocument {
        parsedFlame = nil
        currentTransforms = []
        foundFlameNode = false
        allFlames = []
        parseAllMode = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw FlameParseError.invalidXML
        }
        guard foundFlameNode else {
            throw FlameParseError.noFlameNode
        }
        guard var flame = parsedFlame else {
            throw FlameParseError.invalidXML
        }
        flame.transforms = currentTransforms.filter { $0.weight > 0 }
        guard !flame.transforms.isEmpty else {
            throw FlameParseError.noTransforms
        }
        return flame
    }

    /// Parse ALL `<flame>` nodes from a multi-flame file (e.g. Apophysis .flame collections).
    /// Returns an array of FlameDocument, one per `<flame>` element with at least one transform.
    func parseAll(data: Data) throws -> [FlameDocument] {
        parsedFlame = nil
        currentTransforms = []
        foundFlameNode = false
        allFlames = []
        parseAllMode = true

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw FlameParseError.invalidXML
        }

        // Finalize any in-progress flame
        finalizeCurrentFlame()

        guard !allFlames.isEmpty else {
            throw FlameParseError.noFlameNode
        }
        return allFlames
    }

    /// Finalize the current flame-in-progress and append to allFlames if valid.
    private func finalizeCurrentFlame() {
        guard var flame = parsedFlame else { return }
        let validTransforms = currentTransforms.filter { $0.weight > 0 }
        guard !validTransforms.isEmpty else {
            parsedFlame = nil
            currentTransforms = []
            return
        }
        flame.transforms = validTransforms
        allFlames.append(flame)
        parsedFlame = nil
        currentTransforms = []
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName.lowercased() {
        case "flame":
            // In parseAll mode, finalize any prior flame before starting a new one
            if parseAllMode {
                finalizeCurrentFlame()
            }

            foundFlameNode = true
            let name = attributeDict["name"] ?? "Imported Flame"
            let width = Int(attributeDict["size"]?.split(separator: " ").first ?? "0") ?? 1024
            let height: Int = {
                if let parts = attributeDict["size"]?.split(separator: " "), parts.count > 1 {
                    return Int(parts[1]) ?? 1024
                }
                return 1024
            }()
            let gamma = Float(attributeDict["gamma"] ?? "2.2") ?? 2.2
            let brightness = Float(attributeDict["brightness"] ?? "4.0") ?? 4.0
            parsedFlame = FlameDocument(
                name: name,
                width: max(64, width),
                height: max(64, height),
                gamma: max(0.1, gamma),
                brightness: max(0.01, brightness),
                transforms: []
            )
            currentTransforms = []

        case "xform", "finalxform":
            guard foundFlameNode else { return }

            let weight = Float(attributeDict["weight"] ?? "1") ?? 1
            let color = min(1, max(0, Float(attributeDict["color"] ?? "0.5") ?? 0.5))

            let affine = parseAffine(attributes: attributeDict)
            let variations = parseVariations(attributes: attributeDict)

            currentTransforms.append(
                FlameTransform(
                    weight: max(0, weight),
                    color: color,
                    affine: affine,
                    variations: variations.isEmpty ? ["linear": 1] : variations
                )
            )
        default:
            break
        }
    }

    private func parseAffine(attributes: [String: String]) -> FlameTransform.Affine {
        if let coefs = attributes["coefs"] {
            let vals = coefs
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
                .compactMap { Float($0) }
            if vals.count >= 6 {
                return .init(a: vals[0], b: vals[1], c: vals[2], d: vals[3], e: vals[4], f: vals[5])
            }
        }

        let a = Float(attributes["a"] ?? "1") ?? 1
        let b = Float(attributes["b"] ?? "0") ?? 0
        let c = Float(attributes["c"] ?? "0") ?? 0
        let d = Float(attributes["d"] ?? "1") ?? 1
        let e = Float(attributes["e"] ?? "0") ?? 0
        let f = Float(attributes["f"] ?? "0") ?? 0
        return .init(a: a, b: b, c: c, d: d, e: e, f: f)
    }

    private func parseVariations(attributes: [String: String]) -> [String: Float] {
        // First-pass supported flame variations
        let supported = ["linear", "sinusoidal", "spherical", "swirl", "horseshoe"]
        var out: [String: Float] = [:]
        for name in supported {
            if let raw = attributes[name], let v = Float(raw), v != 0 {
                out[name] = v
            }
        }
        return out
    }
}
