//
//  FractalGridView.swift
//  Threshold
//
//  Grid-based fractal type selector — dedicated "Formulas" tab.
//

import SwiftUI

struct FractalGridView: View {
    @Environment(AppModel.self) private var appModel
    var cache: UISettingsCache

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]

    /// Categories in display order, derived from descriptors.
    private var categorizedTypes: [(category: String, types: [FractalModelType])] {
        let selectable = FractalModelType.selectableCases
        var seen: [String: [FractalModelType]] = [:]
        var order: [String] = []
        for type in selectable {
            let cat = type.category
            if seen[cat] == nil { order.append(cat) }
            seen[cat, default: []].append(type)
        }
        return order.map { (category: $0, types: seen[$0]!) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
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
                                    cache.pushFractalType(type, gestureController: appModel.gestureController)
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
