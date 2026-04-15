//
//  FractalGridView.swift
//  Threshold
//
//  Grid-based fractal type selector — dedicated "Formulas" tab.
//

import SwiftUI

struct FractalGridView: View {
    var cache: UISettingsCache
    let gestureController: GestureController?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]
    private static let categoryOrder = ["Box Folds", "Power / Quaternion", "Hybrid Folds", "Kaleidoscopic IFS"]

    /// Categories in display order, derived once from the selectable descriptors.
    private let categorizedTypes: [(category: String, types: [FractalModelType])]

    /// Cache the category grouping once so entering the tab does not redo the
    /// descriptor walk every time SwiftUI recreates the view.
    private static let cachedCategorizedTypes = Self.makeCategorizedTypes()

    init(cache: UISettingsCache, gestureController: GestureController?) {
        self.cache = cache
        self.gestureController = gestureController
        self.categorizedTypes = Self.cachedCategorizedTypes
    }

    private static func makeCategorizedTypes() -> [(category: String, types: [FractalModelType])] {
        let selectable = FractalModelType.selectableCases
        var seen: [String: [FractalModelType]] = [:]
        var order: [String] = []
        for type in selectable {
            let category = type.category
            if seen[category] == nil { order.append(category) }
            seen[category, default: []].append(type)
        }
        let preferredOrder = categoryOrder.filter { seen[$0] != nil }
        let remainingOrder = order.filter { !categoryOrder.contains($0) }
        return (preferredOrder + remainingOrder).map { category in (category: category, types: seen[category] ?? []) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(categorizedTypes, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.category)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(group.types, id: \.self) { type in
                                FractalGridCell(
                                    type: type,
                                    isSelected: type == cache.fractalType
                                ) {
                                    cache.fractalType = type
                                    cache.pushFractalType(type, gestureController: gestureController)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Grid Cell

private struct FractalGridCell: View {
    let type: FractalModelType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.system(size: 28))
                    .frame(height: 32)

                Text(type.displayName)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.25) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
