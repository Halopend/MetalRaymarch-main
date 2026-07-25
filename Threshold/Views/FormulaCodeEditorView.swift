//
//  FormulaCodeEditorView.swift
//  Threshold
//
//  Mac live-code window: edit a fractal formula's Metal source, watch the
//  parameter sliders regenerate on every keystroke (pragma parse — instant),
//  and see the viewport swap shaders a debounce later (background compile,
//  keep-last-good, errors mapped to source lines inline). Lives in its own
//  window so the fractal viewport stays visible while typing.
//

#if os(macOS)

import SwiftUI

struct FormulaEditorWindowView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: FormulaEditorModel?

    var body: some View {
        Group {
            if !AppModel.allowCustomScenes {
                gateExplainer
            } else if let model {
                FormulaEditorContent(model: model, appModel: appModel)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard AppModel.allowCustomScenes, model == nil else { return }
            let editor = FormulaEditorModel(
                library: appModel.formulaLibrary,
                compileHandler: { [weak appModel] draft in
                    guard let appModel else { return .rendererUnavailable }
                    let outcome = await appModel.installEmbeddedFormulaForLiveEdit(draft)
                    if case .ready = outcome {
                        // First success flips the viewport onto the draft;
                        // until then the previous fractal keeps rendering.
                        if appModel.renderSettings.fractalType != .custom {
                            appModel.renderSettings.fractalType = .custom
                            appModel.controlStateStore.loadFromSettings()
                        }
                    }
                    return outcome
                },
                definitionChangedHandler: { [weak appModel] draft in
                    appModel?.controlStateStore.noteCustomFormulaDefinitionChanged(draft)
                }
            )
            if let seed = appModel.formulaEditorSeed {
                let saved = appModel.formulaLibrary.entry(withHash: seed.shortHash)
                editor.load(seed, savedEntry: saved)
                appModel.formulaEditorSeed = nil
            }
            model = editor
            editor.activate()
        }
    }

    private var gateExplainer: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Custom formulas are experimental")
                .font(.headline)
            Text("Enable “Allow custom scenes” in Settings → General to write live formulas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 260)
    }
}

private struct FormulaEditorContent: View {
    @Bindable var model: FormulaEditorModel
    let appModel: AppModel

    var body: some View {
        HSplitView {
            librarySidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            editorColumn
                .frame(minWidth: 460)
            parameterSidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        }
        .frame(minWidth: 960, minHeight: 560)
    }

    // MARK: - Library

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Button {
                    model.startNewDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New formula")
            }
            List(appModel.formulaLibrary.entries) { entry in
                Button {
                    model.load(entry.formula, savedEntry: entry)
                    model.activate()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.formula.name).font(.callout)
                        Text(entry.formula.shortHash)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Duplicate") { try? appModel.formulaLibrary.duplicate(entry) }
                    Button("Delete", role: .destructive) { try? appModel.formulaLibrary.delete(entry) }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(10)
    }

    // MARK: - Editor

    private var editorColumn: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Formula name", text: Binding(
                    get: { model.name },
                    set: { model.setName($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

                statusPill
                Spacer()

                Button("Compile Now") { model.compileNow() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Save") { try? model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isDirty)
            }

            TextEditor(text: Binding(
                get: { model.source },
                set: { model.setSource($0) }
            ))
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.08))
            .cornerRadius(6)

            if !diagnostics.isEmpty {
                diagnosticsList
                    .frame(maxHeight: 140)
            }
        }
        .padding(10)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch model.status {
        case .idle: ("Idle", .secondary)
        case .blockedByParseIssues: ("Fix pragmas", .orange)
        case .compiling: ("Compiling…", .yellow)
        case .live: ("Live", .green)
        case .compileFailed: ("\(model.compileDiagnostics.filter { $0.severity == .error }.count) error(s)", .red)
        case .disabled: ("Disabled", .secondary)
        case .rendererUnavailable: ("Renderer starting…", .secondary)
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private struct DiagnosticRow: Identifiable {
        let id = UUID()
        let line: Int?
        let severity: String
        let message: String
        let isError: Bool
    }

    private var diagnostics: [DiagnosticRow] {
        model.pragmaDiagnostics.map {
            DiagnosticRow(line: $0.line, severity: $0.severity == .error ? "error" : "warning",
                          message: $0.message, isError: $0.severity == .error)
        } + model.compileDiagnostics.map {
            DiagnosticRow(line: $0.userLine, severity: $0.severity.rawValue,
                          message: $0.message, isError: $0.severity == .error)
        }
    }

    private var diagnosticsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diagnostics) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.line.map { "L\($0)" } ?? "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(row.severity)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(row.isError ? .red : .orange)
                        Text(row.message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: - Parameters

    private var parameterSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Parameters")
                    .font(.headline)
                Text("Declared by // @param pragmas; sliders regenerate as you type. Values drive the running shader immediately.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                FormulaParamsEditor(cache: appModel.controlStateStore)
            }
            .padding(10)
        }
    }
}

#endif
