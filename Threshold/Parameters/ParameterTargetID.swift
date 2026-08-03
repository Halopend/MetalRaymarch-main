import Foundation

enum ParameterTargetID {
    enum Core {
        static let fractalScale = "core.fractalScale"
        static let colorMix = "core.colorMix"
        static let iterations = "core.iterations"
    }

    enum Effect {
        static let glow = "effect.glow"
        static let fog = "effect.fog"
        static let bloom = "effect.bloom"
        static let hueSpeed = "effect.hueSpeed"
        static let saturation = "effect.saturation"
        static let safetyBubbleRadius = "effect.safetyBubbleRadius"
        static let gradientOffset = "effect.gradientOffset"
    }

    /// Space-transform scalars (cross-fractal). Routed like core/effect params so
    /// they can be driven by gesture and music, not just the slider.
    enum Space {
        static let sphereProjectionBlend = "space.sphereProjectionBlend"
        static let sphereProjectionRadius = "space.sphereProjectionRadius"
        static let spaceWarpStrength = "space.spaceWarpStrength"
        static let spaceWarpOriginX = "space.spaceWarpOriginX"
        static let spaceWarpOriginY = "space.spaceWarpOriginY"
        static let spaceWarpOriginZ = "space.spaceWarpOriginZ"
    }

    /// Composable transform-stack slots (music-bindable). DYNAMIC, like formula slots:
    /// they resolve against the LIVE stack, so they carry `nil` static target ids and
    /// stay out of the routed-node lockstep (`validateStartupRouting`). The music engine
    /// folds each mapping's selected `SpaceWarpField` into the live stack per frame.
    enum SpaceWarp {
        static func opStrength(slot: Int) -> String { "spacewarp.\(slot).strength" }
    }

    static func formula(fractalType: FractalModelType, formulaIndex: Int, name: String) -> String {
        "formula.\(fractalType.rawValue).\(formulaIndex).\(name)"
    }

    static func parseFormulaID(_ id: String) -> (fractalType: FractalModelType, formulaIndex: Int)? {
        let pieces = id.split(separator: ".")
        guard pieces.count >= 4,
              pieces[0] == "formula",
              let fractalRaw = Int(pieces[1]),
              let formulaIndex = Int(pieces[2]),
              let fractalType = FractalModelType(rawValue: Int32(fractalRaw)) else {
            return nil
        }
        return (fractalType, formulaIndex)
    }
}

enum ParameterRoutingValidation {
    static func validateStartupRouting() {
        let registry = ParameterNodeRegistry.shared
        let nodeIDs = Set(registry.coreNodes.keys).union(registry.effectNodes.keys)
        let specIDs = Set(ControlCatalog.allSpecs.map(\.id))
        let mappedMusicTargets = Set(MusicReactiveTarget.availableCases.compactMap(\.parameterTargetID))

        // ControlCatalog.allSpecs remains an independently enumerated completeness
        // list, so bidirectional equality catches a spec without a descriptor/node
        // and a descriptor/node omitted from the list.
        precondition(specIDs == nodeIDs,
                     "Routed spec/node set mismatch: specs \(specIDs.sorted()) != nodes \(nodeIDs.sorted()).")
        precondition(mappedMusicTargets.isSubset(of: nodeIDs),
                     "One or more music-reactive target IDs do not resolve to a routed node.")

        // ControlCatalog is the single source of truth for range/default/name/icon.
        // Guard that the live consumers haven't re-hardcoded a divergent range —
        // this is what caught the Fractal Scale -3...5 vs -5...8 drift.
        for spec in ControlCatalog.allSpecs {
            let node = registry.coreNodes[spec.id] ?? registry.effectNodes[spec.id]
            precondition(node != nil, "ControlCatalog spec '\(spec.id)' has no matching parameter node.")
            if let node {
                precondition(node.range == spec.range,
                             "Range drift: node '\(spec.id)' \(node.range) != ControlCatalog \(spec.range).")
            }
            if let target = MusicReactiveTarget.availableCases.first(where: { $0.parameterTargetID == spec.id }) {
                precondition(target.allowedRange == spec.range,
                             "Range drift: music target for '\(spec.id)' \(target.allowedRange) != ControlCatalog \(spec.range).")
            }
        }

        // Per-fractal FORMULA nodes are dynamic (FormulaCatalog-driven), so they live
        // outside ParameterCatalog — but bring their ranges under the same drift
        // tripwire: a node's range must match its authoring FormulaParamDescriptor.
        // Additive guard, no behavior change; matches buildFormulaBatch by construction.
        for type in FractalModelType.allCases {
            guard let descriptor = FormulaCatalog.shared.descriptor(for: type) else { continue }
            let batch = registry.formulaBatch(for: type)
            for param in descriptor.params where !(param.isBool ?? false) && !(param.isHidden ?? false) {
                if let node = batch.floatNodeByFormulaIndex[param.index] {
                    precondition(node.range == param.min...param.max,
                                 "Formula range drift: \(type) param '\(param.name)' node \(node.range) != descriptor \(param.min...param.max).")
                }
            }
        }
    }
}
