import Foundation

struct ControlCatalogProjectionKey: Hashable, Sendable {
    let profile: PlatformProfile
    /// A concrete route for full/radial projections. `nil` projects a
    /// presentation-wide surface such as Quick Toggles across all home routes.
    let route: AppRoute?
    let presentation: ControlPresentation
    let fractalType: FractalModelType
    let catalogRevision: Int
    let transformRevision: Int
    let featureFlags: UInt64
}

struct ControlCatalogSection: Hashable, Sendable {
    let name: String
    let controlIDs: [ControlID]
}

/// Caches immutable semantic projections. Live values are deliberately absent
/// from the key, so dragging a slider never rebuilds the hierarchy.
@MainActor
final class ControlCatalogProjectionCache {
    private var projections: [ControlCatalogProjectionKey: [ControlCatalogSection]] = [:]

    func sections(for key: ControlCatalogProjectionKey) -> [ControlCatalogSection] {
        if let cached = projections[key] { return cached }

        let eligible: [(descriptor: SemanticControlDescriptor, section: String, order: Int)] =
            ParameterCatalog.semanticDescriptors.compactMap { descriptor in
                guard descriptor.isAvailable(for: key.fractalType),
                      key.profile.supports(descriptor.requiredPlatformCapabilities),
                      case .presented(let route, let section, let order, let presentations) = descriptor.placement,
                      key.route == nil || route == key.route,
                      presentations.contains(key.presentation) else { return nil }
                return (descriptor, section, order)
            }

        var sectionOrder: [String] = []
        var grouped: [String: [(Int, ControlID)]] = [:]
        grouped.reserveCapacity(eligible.count)
        for item in eligible {
            if grouped[item.section] == nil { sectionOrder.append(item.section) }
            grouped[item.section, default: []].append((item.order, item.descriptor.id))
        }

        let result = sectionOrder.compactMap { section -> ControlCatalogSection? in
            guard let entries = grouped[section] else { return nil }
            return ControlCatalogSection(
                name: section,
                controlIDs: entries.sorted { lhs, rhs in
                    lhs.0 == rhs.0 ? lhs.1.rawValue < rhs.1.rawValue : lhs.0 < rhs.0
                }.map(\.1)
            )
        }
        projections[key] = result
        return result
    }

    func invalidate() {
        projections.removeAll(keepingCapacity: true)
    }
}

/// The sole live binding resolver used at presentation edges.
@MainActor
final class ControlAccessService {
    private let store: ControlStateStore

    init(store: ControlStateStore) {
        self.store = store
    }

    func read(_ id: ControlID) -> Float? {
        ParameterCatalog.allByID[id.rawValue].map { $0.ui.read(store) }
    }

    func write(_ value: Float, to id: ControlID) {
        guard let descriptor = ParameterCatalog.allByID[id.rawValue] else { return }
        descriptor.ui.write(store, descriptor.clamp(value))
    }

    func readToggle(_ id: ControlID) -> Bool? {
        guard case .toggle(let descriptor) = ParameterCatalog.semanticByID[id] else { return nil }
        return descriptor.read(store)
    }

    func writeToggle(_ value: Bool, to id: ControlID) {
        guard case .toggle(let descriptor) = ParameterCatalog.semanticByID[id] else { return }
        descriptor.write(store, value)
    }
}
