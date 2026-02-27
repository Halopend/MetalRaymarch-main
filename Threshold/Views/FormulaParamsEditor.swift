//
//  FormulaParamsEditor.swift
//  Threshold
//
//  Data-driven parameter editor for non-Mandelbox fractal formulas.
//  Reads FormulaDescriptor from FormulaCatalog to generate sliders/toggles.
//  Uses the same EffectSliderRow pattern as the rest of the UI.
//

import SwiftUI

// MARK: - FormulaParamsEditor

/// Generates UI controls for the current fractal's formula parameters.
/// Driven entirely by catalog.json metadata — zero per-formula view code.
struct FormulaParamsEditor: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var cache: UISettingsCache
    
    /// Cached descriptor lookup — only recomputed when fractalType changes.
    private var descriptor: FormulaDescriptor? {
        FormulaCatalog.shared.descriptor(for: cache.fractalType)
    }
    
    var body: some View {
        if let desc = descriptor, !(desc.usesMandelboxParams ?? false), !desc.params.isEmpty {
            VStack(spacing: 4) {
                // Header
                HStack {
                    Label("\(desc.name) Parameters", systemImage: cache.fractalType.icon)
                        .font(.headline)
                    Spacer()
                    Button {
                        cache.resetFormulaParams()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to defaults")
                }
                .padding(.bottom, 4)
                
                // Description
                Text(desc.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                
                // Parameter controls
                ForEach(Array(desc.params.enumerated()), id: \.element.id) { idx, param in
                    if idx > 0 {
                        Divider().padding(.leading, 159)
                    }
                    FormulaParamRow(cache: cache, param: param)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.06)))
        }
    }
}

// MARK: - FormulaParamRow

/// Single parameter row: bool → Toggle, numeric → EffectSliderRow.
/// Reads/writes through FormulaCatalog.getParam/setParam for performance.
private struct FormulaParamRow: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var cache: UISettingsCache
    let param: FormulaParamDescriptor
    
    /// Display-friendly label: "JuliaC.x" → "Julia C X", "MinRad2" → "Min Rad 2"
    private var displayLabel: String {
        // Split camelCase/dots into words, capitalize each
        let raw = param.name
            .replacingOccurrences(of: ".", with: " ")
        // Insert spaces before uppercase letters following lowercase
        var result = ""
        for (i, ch) in raw.enumerated() {
            if i > 0 && ch.isUppercase && raw[raw.index(raw.startIndex, offsetBy: i - 1)].isLowercase {
                result += " "
            }
            result += String(ch)
        }
        return result
    }
    
    /// Icon for the parameter based on name patterns
    private var icon: String {
        let name = param.name.lowercased()
        if name.contains("scale") { return "arrow.up.left.and.arrow.down.right" }
        if name.contains("power") { return "bolt" }
        if name.contains("bailout") || name.contains("threshold") { return "exclamationmark.triangle" }
        if name.contains("julia") { return "sparkle" }
        if name.contains("offset") { return "arrow.up.and.down.and.arrow.left.and.right" }
        if name.contains("fold") { return "arrow.triangle.branch" }
        if name.contains("size") || name.contains("rad") { return "circle.dashed" }
        if name.contains("rot") || name.contains("angle") || name.contains("twiddle") { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if name.contains("phi") { return "fibrechannel" }
        if name.contains("de") { return "ruler" }
        if name.hasPrefix("c.") || name.hasPrefix("g.") { return "cube" }
        if name.contains("pre") { return "arrow.right" }
        if name.contains("bubble") { return "circle.grid.3x3" }
        return "slider.horizontal.3"
    }
    
    var body: some View {
        if param.isBool == true {
            boolRow
        } else {
            sliderRow
        }
    }
    
    // MARK: - Bool Row (Toggle)
    
    private var boolRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 16)
            Text(displayLabel)
                .font(.subheadline)
                .frame(width: 135, alignment: .leading)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding<Bool>(
                get: { FormulaCatalog.getParam(cache.formulaParams, index: param.index) > 0.5 },
                set: { newVal in
                    cache.pushFormulaParam(index: param.index, value: newVal ? 1.0 : 0.0)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .frame(height: 32)
    }
    
    // MARK: - Slider Row
    
    private var sliderRow: some View {
        EffectSliderRow(
            icon: icon,
            label: displayLabel,
            value: Binding<Float>(
                get: { FormulaCatalog.getParam(cache.formulaParams, index: param.index) },
                set: { newVal in
                    cache.pushFormulaParam(index: param.index, value: newVal)
                }
            ),
            range: param.min ... param.max,
            enabled: .constant(true),
            onChanged: { /* push already handled in Binding setter */ },
            showToggle: false
        )
    }
}
