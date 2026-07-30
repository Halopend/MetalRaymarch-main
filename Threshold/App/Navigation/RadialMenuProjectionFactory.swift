import Foundation

/// Presentation policy for route controls. Touch users get the controls
/// directly; pointer users retain authored section grouping for hover
/// navigation. Both shapes use the same compact overflow destination.
enum RadialRouteLayoutPolicy {
    static let compactItemLimit = 8

    static func children(
        from sections: [RadialNavigationNode],
        flattenSections: Bool
    ) -> [RadialNavigationNode] {
        flattenSections ? sections.flatMap(\.children) : sections
    }
}

/// Produces the universal 2-D radial tree from the same navigation and control
/// catalogs as Finder/full controls. Values remain live through the access
/// service; cache keys contain structure only.
@MainActor
enum RadialMenuProjectionFactory {
    static func make(
        appModel: AppModel,
        allowsCustomScenes: Bool = AppModel.allowCustomScenes,
        featureFlags: UInt64 = 0,
        onActivate: @escaping (AppNavigationTarget) -> Void
    ) -> RadialNavigationProjection {
        let hierarchy = NavigationHierarchy.application(availability: .resolve(
            profile: appModel.platformProfile,
            allowsCustomScenes: allowsCustomScenes,
            includesGestureEditing: true
        ))
        return RadialNavigationProjection(
            roots: hierarchy.roots.map {
                node($0, appModel: appModel, featureFlags: featureFlags, onActivate: onActivate)
            }
        )
    }

    private static func node(
        _ definition: NavigationHierarchy.Node,
        appModel: AppModel,
        featureFlags: UInt64,
        onActivate: @escaping (AppNavigationTarget) -> Void
    ) -> RadialNavigationNode {
        if definition.isBranch {
            return RadialNavigationNode(
                id: definition.id,
                title: definition.title,
                systemImage: definition.systemImage,
                isSelected: selected(definition.target, in: appModel.navigationStore.state),
                children: definition.children.map {
                    node($0, appModel: appModel, featureFlags: featureFlags, onActivate: onActivate)
                },
                fullControlsAction: { onActivate(definition.target) }
            )
        }

        guard case .route(let route) = definition.target else {
            return actionNode(definition, onActivate: onActivate)
        }

        let key = ControlCatalogProjectionKey(
            profile: appModel.platformProfile,
            route: route,
            presentation: .radial2D,
            fractalType: appModel.controlStateStore.fractalType,
            catalogRevision: 1,
            transformRevision: appModel.controlStateStore.spaceWarpStructureRevision,
            featureFlags: featureFlags
        )
        var sections = appModel.controlProjectionCache.sections(for: key).compactMap { section -> RadialNavigationNode? in
            let controls = section.controlIDs.compactMap {
                controlNode($0, appModel: appModel, onActivate: onActivate)
            }
            guard !controls.isEmpty else { return nil }
            let sectionID = "\(definition.id).section.\(section.name)"
            return compactBranch(
                id: sectionID,
                title: section.name,
                systemImage: "slider.horizontal.3",
                children: controls,
                fallbackID: "\(sectionID).more",
                fallbackTitle: "All \(section.name) Controls",
                fallbackAction: { onActivate(definition.target) },
                fullControlsAction: { onActivate(definition.target) }
            )
        }
        sections.append(contentsOf: generatedSections(
            for: route,
            appModel: appModel,
            onActivate: onActivate
        ))

        guard !sections.isEmpty else { return actionNode(definition, onActivate: onActivate) }
        let children = RadialRouteLayoutPolicy.children(
            from: sections,
            flattenSections: appModel.platformProfile.platform == .iPadOS
        )
        return RadialNavigationNode(
            id: definition.id,
            title: definition.title,
            systemImage: definition.systemImage,
            isSelected: selected(definition.target, in: appModel.navigationStore.state),
            children: children,
            fullControlsAction: { onActivate(definition.target) },
            compactChildrenLimit: RadialRouteLayoutPolicy.compactItemLimit,
            overflowFallback: RadialOverflowFallback(
                RadialNavigationNode(
                    id: "\(definition.id).more",
                    title: "All \(definition.title) Controls",
                    systemImage: "ellipsis.circle",
                    fallbackAction: { onActivate(definition.target) }
                )
            )
        )
    }

    /// Formula and transform-instance controls are schema/instance authored, so
    /// they remain generated while using stable semantic IDs and the same live
    /// access edge as catalog controls.
    private static func generatedSections(
        for route: AppRoute,
        appModel: AppModel,
        onActivate: @escaping (AppNavigationTarget) -> Void
    ) -> [RadialNavigationNode] {
        switch route {
        case .shape(.parameters):
            let store = appModel.controlStateStore
            let nodes = ParameterNodeRegistry.shared
                .formulaBatch(for: store.fractalType)
                .floatNodes
                .map { node in
                    RadialNavigationNode(
                        id: "control.formula.\(node.id)",
                        title: node.name,
                        systemImage: node.icon,
                        slider: RadialSliderBinding(
                            range: node.range,
                            read: { node.readValue(store) },
                            write: { value in
                                store.dispatchParameterOperation(ParameterOperation(
                                    targetID: node.id,
                                    source: .slider,
                                    value: value,
                                    frameIndex: 0,
                                    smoothing: ParameterOperationSmoothing(smoothingTime: 0)
                                ))
                            },
                            format: valueFormatter(for: node.range)
                        )
                    )
                }
            guard !nodes.isEmpty else { return [] }
            return [RadialNavigationNode(
                id: "shape.parameters.formula",
                title: "Formula",
                systemImage: "function",
                children: nodes,
                fullControlsAction: { onActivate(.route(route)) }
            )]

        case .shape(.primitives):
            let store = appModel.controlStateStore
            let selected: FractalPrimitiveKind? = store.fractalType == .constructionPrimitive
                ? FractalPrimitiveKind(rawSelector: FormulaCatalog.getParam(store.formulaParams, index: 0))
                : nil
            let nodes = FractalPrimitiveKind.analyticCases.map { primitive in
                RadialNavigationNode(
                    id: "control.primitive.\(primitive.id)",
                    title: primitive.name,
                    systemImage: primitive.icon,
                    isSelected: selected == primitive,
                    fallbackAction: { store.pushConstructionPrimitive(primitive) }
                )
            }
            return [RadialNavigationNode(
                id: "shape.primitives.catalog",
                title: "Primitive",
                systemImage: "cube.transparent",
                children: nodes,
                fullControlsAction: { onActivate(.route(route)) }
            )]

        case .shape(.transformations):
            let store = appModel.controlStateStore
            let defaults = UserDefaults.standard
            let mode = TransformationExperienceMode.decode(
                defaults.string(forKey: TransformationExperienceMode.defaultsKey) ?? ""
            )
            let mappedIDs = TransformationUnlockProgress.runtimeKindIDs(
                from: TransformationUnlockProgress.decode(
                    defaults.string(forKey: TransformationUnlockProgress.defaultsKey) ?? "",
                    legacyEncoded: defaults.string(forKey: TransformationUnlockProgress.legacyDefaultsKey) ?? ""
                )
            )
            let nodes = store.spaceWarpStack.enumerated().compactMap { position, operation -> RadialNavigationNode? in
                guard TransformationAccessPolicy.canInteract(
                    withRawKindID: operation.type,
                    mode: mode,
                    mappedIDs: mappedIDs
                ) else { return nil }
                return RadialTransformNodeFactory.branch(
                    for: operation,
                    position: position,
                    read: { id in store.renderSettings?.spaceWarpStack.first { $0.id == id } },
                    update: { id, mutate in store.updateSpaceWarpOp(id: id, mutate) },
                    fullControlsAction: { onActivate(.route(route)) }
                )
            }
            guard !nodes.isEmpty else { return [] }
            return [RadialNavigationNode(
                id: "shape.transformations.instances",
                title: "Transform Stack",
                systemImage: "square.stack.3d.up",
                children: nodes,
                fullControlsAction: { onActivate(.route(route)) }
            )]

        default:
            return []
        }
    }

    private static func actionNode(
        _ definition: NavigationHierarchy.Node,
        onActivate: @escaping (AppNavigationTarget) -> Void
    ) -> RadialNavigationNode {
        RadialNavigationNode(
            id: definition.id,
            title: definition.title,
            systemImage: definition.systemImage,
            fallbackAction: { onActivate(definition.target) }
        )
    }

    private static func controlNode(
        _ id: ControlID,
        appModel: AppModel,
        onActivate: @escaping (AppNavigationTarget) -> Void
    ) -> RadialNavigationNode? {
        guard let semantic = ParameterCatalog.semanticByID[id] else { return nil }
        switch semantic {
        case .scalar(let descriptor):
            let access = appModel.controlAccessService
            let range = descriptor.spec.range
            return RadialNavigationNode(
                id: "control.\(id.rawValue)",
                title: descriptor.spec.name,
                systemImage: descriptor.spec.icon,
                slider: RadialSliderBinding(
                    range: range,
                    read: { access.read(id) ?? range.lowerBound },
                    write: { access.write($0, to: id) },
                    format: valueFormatter(for: range)
                )
            )

        case .toggle(let descriptor):
            let access = appModel.controlAccessService
            guard descriptor.isAvailable(appModel.controlStateStore) else { return nil }
            return RadialNavigationNode(
                id: "control.\(id.rawValue)",
                title: descriptor.name,
                systemImage: descriptor.icon,
                toggle: RadialToggleBinding(
                    read: { access.readToggle(id) ?? false },
                    write: { access.writeToggle($0, to: id) },
                    isEnabled: { descriptor.isAvailable(appModel.controlStateStore) }
                )
            )

        case .action(let descriptor):
            return RadialNavigationNode(
                id: "control.\(id.rawValue)",
                title: descriptor.name,
                systemImage: descriptor.icon,
                fallbackAction: { onActivate(.command(descriptor.command)) }
            )
        }
    }

    private static func selected(_ target: AppNavigationTarget, in state: NavigationState) -> Bool {
        switch target {
        case .workspace(let root):
            return state.currentRoute.workspaceRoot == root
        case .route(let route):
            return state.currentRoute == route
        case .command:
            return false
        }
    }

    private static func compactBranch(
        id: String,
        title: String,
        systemImage: String,
        children: [RadialNavigationNode],
        fallbackID: String,
        fallbackTitle: String,
        fallbackAction: @escaping () -> Void,
        fullControlsAction: @escaping () -> Void
    ) -> RadialNavigationNode {
        RadialNavigationNode(
            id: id,
            title: title,
            systemImage: systemImage,
            children: children,
            fullControlsAction: fullControlsAction,
            compactChildrenLimit: RadialRouteLayoutPolicy.compactItemLimit,
            overflowFallback: RadialOverflowFallback(
                RadialNavigationNode(
                    id: fallbackID,
                    title: fallbackTitle,
                    systemImage: "ellipsis.circle",
                    fallbackAction: fallbackAction
                )
            )
        )
    }

    private static func valueFormatter(for range: ClosedRange<Float>) -> (Float) -> String {
        range.upperBound - range.lowerBound >= 8
            ? { String(format: "%.1f", $0) }
            : { String(format: "%.2f", $0) }
    }
}
