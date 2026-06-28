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

    static let coreAndEffect: [String] = [
        Core.fractalScale,
        Core.colorMix,
        Core.iterations,
        Effect.glow,
        Effect.fog,
        Effect.bloom,
        Effect.hueSpeed,
        Effect.saturation,
        Effect.safetyBubbleRadius,
        Space.sphereProjectionBlend,
        Space.sphereProjectionRadius,
        Space.spaceWarpStrength,
        Space.spaceWarpOriginX,
        Space.spaceWarpOriginY,
        Space.spaceWarpOriginZ
    ]

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
        let dispatcherIDs = ParameterOperationDispatcher.routableDescriptorTargetIDs
        let nodeIDs = Set(registry.coreNodes.keys).union(registry.effectNodes.keys)
        let mappedMusicTargets = Set(MusicReactiveTarget.availableCases.compactMap(\.parameterTargetID))

        precondition(dispatcherIDs == nodeIDs, "Canonical parameter ID mismatch between dispatcher descriptors and ParameterNodeRegistry nodes.")
        precondition(mappedMusicTargets.isSubset(of: dispatcherIDs), "One or more music-reactive target IDs do not resolve to a canonical descriptor/node.")

        for id in dispatcherIDs {
            let descriptorCount = dispatcherIDs.contains(id) ? 1 : 0
            let nodeCount = (registry.coreNodes[id] != nil ? 1 : 0) + (registry.effectNodes[id] != nil ? 1 : 0)
            precondition(descriptorCount == 1 && nodeCount == 1, "Routable target ID '\(id)' must resolve to exactly one descriptor and one node.")
        }

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
        let catalogIDs = Set(ParameterCatalog.routedDescriptors.map(\.id))
        precondition(catalogIDs == Set(ParameterTargetID.coreAndEffect),
                     "ParameterCatalog/coreAndEffect id set mismatch.")
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
