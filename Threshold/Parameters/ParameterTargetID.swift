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
    /// folds their offset straight into `spaceWarpStack[slot].strength` per frame.
    enum SpaceWarp {
        static func opStrength(slot: Int) -> String { "spacewarp.\(slot).strength" }
    }

    /// Routed core/effect/space ids — DERIVED from the authored `ParameterCatalog`
    /// (Slice 2). Order matches `routedDescriptors` declaration order, which matches
    /// the former hand-listed order. Only ever consumed as a `Set`, so order is moot.
    static var coreAndEffect: [String] { ParameterCatalog.routedDescriptors.map(\.id) }

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

        // Slice 2: `coreAndEffect` / `routableDescriptorTargetIDs` now DERIVE from
        // ParameterCatalog, so the former dispatcher==nodes and per-id-count checks
        // would be tautological. Anchor the tripwire on `ControlCatalog.allSpecs` —
        // the hand-authored range source, which is NOT derived from the node list —
        // with BIDIRECTIONAL equality, catching a spec without a node AND a node
        // without a spec.
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

#if DEBUG
        // ── Parameter-hierarchy Slice 1 golden net ─────────────────────────────
        // Prove the new `ParameterCatalog` mirrors the live registries before any
        // later slice makes a registry DERIVE from it. Nothing consumes the catalog
        // yet; these asserts only confirm equality, so the migration stays reversible.
        // (The `catalogIDs == coreAndEffect` check is gone — coreAndEffect now derives
        // from the catalog, so it would be tautological. Validate the catalog directly
        // against the independently-built nodes instead.)
        let catalogIDs = Set(ParameterCatalog.routedDescriptors.map(\.id))
        precondition(catalogIDs == nodeIDs,
                     "ParameterCatalog/node id set mismatch.")
        for descriptor in ParameterCatalog.routedDescriptors {
            guard let spec = ControlCatalog.spec(descriptor.id) else {
                preconditionFailure("ParameterCatalog descriptor '\(descriptor.id)' has no ControlCatalog spec.")
            }
            precondition(descriptor.spec.range == spec.range
                         && descriptor.spec.motionStrategy == spec.motionStrategy,
                         "ParameterCatalog spec drift on '\(descriptor.id)'.")
        }
        // Music facets must equal the MusicReactiveTarget switch results, so the
        // §3.5 switch-body deletion in a later slice is provably byte-stable.
        for target in MusicReactiveTarget.availableCases {
            guard let id = target.parameterTargetID,
                  let facet = ParameterCatalog.byID[id]?.music else { continue }
            precondition(facet.category == target.category
                         && facet.defaultSource == target.defaultSource
                         && facet.defaultResponseCurve == target.defaultResponseCurve
                         && facet.hasFlashingRisk == target.hasFlashingRisk,
                         "ParameterCatalog music facet drift on '\(id)'.")
        }
#endif
    }
}
