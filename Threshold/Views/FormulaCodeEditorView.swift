//
//  FormulaCodeEditorView.swift
//  Threshold
//
//  Cross-platform live-code workspace: edit a fractal formula's Metal source, watch the
//  parameter sliders regenerate on every keystroke (pragma parse — instant),
//  and see the viewport swap shaders a debounce later (background compile,
//  keep-last-good, errors mapped to source lines inline). It uses a separate
//  window on macOS and a full-screen workspace on iPadOS.
//

#if os(macOS) || os(iOS)

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct FormulaEditorWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: FormulaEditorModel?
    var onClose: (() -> Void)? = nil
    #if os(iOS)
    @State private var isPreviewingRender = false
    #endif

    var body: some View {
        #if os(iOS)
        ZStack(alignment: .bottomTrailing) {
            NavigationStack {
                editorBody
                    .navigationTitle("Metal DE Studio")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                model?.invalidate()
                                if let onClose {
                                    onClose()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
            }
            .opacity(isPreviewingRender ? 0 : 1)
            .allowsHitTesting(!isPreviewingRender)

            renderPreviewControl
                .padding(.trailing, 20)
                .padding(.bottom, UIDevice.current.userInterfaceIdiom == .phone ? 0 : 20)
        }
        .onDisappear { isPreviewingRender = false }
        #else
        editorBody
        #endif
    }

    private var editorBody: some View {
        Group {
            if let model {
                FormulaEditorContent(model: model, appModel: appModel)
            } else {
                ProgressView()
            }
        }
        // Window close (macOS) or cover teardown (iPadOS): stop any compile
        // still in flight so it cannot replace a formula chosen afterwards.
        .onDisappear { model?.invalidate() }
        .onChange(of: appModel.formulaEditorSeed?.formula.id) { _, seedID in
            guard seedID != nil, let model else { return }
            consumeSeed(into: model)
        }
        .onAppear {
            guard model == nil else { return }
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
            model = editor
            if !consumeSeed(into: editor) {
                editor.activate()
            }
        }
    }

    /// Returns true when a pending request was consumed. This also handles the
    /// macOS case where `openWindow` focuses an already-open Studio instead of
    /// constructing a new window (and therefore does not run `onAppear` again).
    @discardableResult
    private func consumeSeed(into editor: FormulaEditorModel) -> Bool {
        guard let seed = appModel.formulaEditorSeed else { return false }
        let saved = appModel.formulaLibrary.entry(withHash: seed.formula.shortHash)
        editor.setAutomaticallyCompilesEdits(seed.activatesImmediately)
        editor.load(seed.formula, savedEntry: saved)
        appModel.formulaEditorSeed = nil
        if seed.activatesImmediately {
            editor.activate()
        }
        return true
    }

    #if os(iOS)
    private var renderPreviewControl: some View {
        HStack(spacing: 7) {
            Image(systemName: isPreviewingRender ? "eye.fill" : "eye")
            if !isPreviewingRender {
                Text("Hold to Preview")
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, isPreviewingRender ? 14 : 16)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: Capsule())
        .contentShape(Capsule())
        .shadow(radius: 6, y: 2)
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { isPressed in
                // The pressing edge is delivered on touch-down/touch-up. Do not
                // animate or debounce it: preview must track the finger exactly.
                isPreviewingRender = isPressed
            },
            perform: {}
        )
        .accessibilityLabel("Preview fractal rendering")
        .accessibilityHint("Touch and hold to hide Metal DE Studio; release to return")
    }
    #endif

}

private struct FormulaEditorContent: View {
    @Bindable var model: FormulaEditorModel
    let appModel: AppModel

    @State private var inspectorTab: InspectorTab = .parameters
    @State private var reportSubmissionStatus: String?
    @State private var libraryErrorMessage: String?
    #if os(iOS)
    @State private var isLibraryPresented = false
    #endif

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case parameters = "Params"
        case learn = "Learn"
        case performance = "Perf"

        var id: String { rawValue }
    }

    var body: some View {
        #if os(macOS)
        HSplitView {
            librarySidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            editorColumn
                .frame(minWidth: 460)
            inspectorSidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        }
        .frame(minWidth: 960, minHeight: 560)
        #else
        GeometryReader { geometry in
            let inspectorWidth = min(400, max(260, geometry.size.width * 0.38))

            if UIDevice.current.userInterfaceIdiom == .phone {
                VStack(spacing: 0) {
                    editorColumn
                        .frame(height: geometry.size.height * 0.56)
                        .background(.ultraThinMaterial)
                    Divider()
                    inspectorSidebar
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.thinMaterial)
                }
            } else {
                HStack(spacing: 0) {
                    editorColumn
                        .frame(width: max(0, geometry.size.width - inspectorWidth - 1))
                        .background(.ultraThinMaterial)
                    Divider()
                    inspectorSidebar
                        .frame(width: inspectorWidth)
                        .background(.thinMaterial)
                }
            }
        }
        .sheet(isPresented: $isLibraryPresented) {
            NavigationStack {
                librarySidebar
                    .navigationTitle("Formula Library")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isLibraryPresented = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
    }

    // MARK: - Library

    private var librarySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Button {
                    model.setAutomaticallyCompilesEdits(true)
                    model.startNewDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New formula")
            }
            List(appModel.formulaLibrary.entries) { entry in
                Button {
                    model.setAutomaticallyCompilesEdits(true)
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
                    Button("Duplicate") { performLibraryAction("duplicate") { try appModel.formulaLibrary.duplicate(entry) } }
                    Button("Delete", role: .destructive) { performLibraryAction("delete") { try appModel.formulaLibrary.delete(entry) } }
                }
            }
            .listStyle(.sidebar)
            if let libraryErrorMessage {
                Text(libraryErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Library error: \(libraryErrorMessage)")
            }
        }
        .padding(10)
    }

    private func performLibraryAction(_ verb: String, _ action: () throws -> Void) {
        do {
            try action()
            libraryErrorMessage = nil
        } catch {
            libraryErrorMessage = "Couldn't \(verb) formula: \(error.localizedDescription)"
        }
    }

    /// Shown under the editor's toolbar row when the last Save failed.
    @ViewBuilder
    private var saveErrorBanner: some View {
        if let message = model.saveErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Save failed: \(message)")
        }
    }

    // MARK: - Editor

    private var editorColumn: some View {
        VStack(spacing: 8) {
            #if os(macOS)
            HStack(spacing: 10) {
                Label("Metal DE Studio", systemImage: "hammer.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                    .help("Write a Metal distance estimator")

                Text("macOS")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .foregroundStyle(.secondary)

                TextField("Formula name", text: Binding(
                    get: { model.name },
                    set: { model.setName($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

                statusPill
                Spacer()

                Button {
                    inspectorTab = .learn
                } label: {
                    Label("Metal / GLSL guide", systemImage: "book.pages")
                }
                .buttonStyle(.borderless)
                .help("Read the differences that matter when porting a GLSL DE to Metal")

                Button("Compile Now") { model.compileNow() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Save") { model.saveReportingErrors() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isDirty)
            }
            saveErrorBanner
            #else
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        isLibraryPresented = true
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Formula Library")

                    statusPill
                    Spacer()
                    Button("Compile") { model.compileNow() }
                        .buttonStyle(.borderedProminent)
                    Button("Save") { model.saveReportingErrors() }
                        .buttonStyle(.bordered)
                        .disabled(!model.isDirty)
                }
                saveErrorBanner

                TextField("Formula name", text: Binding(
                    get: { model.name },
                    set: { model.setName($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
            #endif

            TextEditor(text: Binding(
                get: { model.source },
                set: { model.setSource($0) }
            ))
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            // The editor surface is deliberately dark in every app appearance.
            // Keep AppKit/UIKit's text, insertion point, and selection colors in
            // the matching appearance as well (especially in macOS Light Mode).
            .colorScheme(.dark)
            .scrollContentBackground(.hidden)
            #if os(iOS)
            .background(Color.black.opacity(0.52))
            #else
            .background(Color(white: 0.08))
            #endif
            .cornerRadius(6)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            #endif

            if !diagnostics.isEmpty {
                diagnosticsList
                    .frame(maxHeight: 140)
            }
        }
        .padding(10)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = switch model.status {
        case .idle: (model.automaticallyCompilesEdits ? "Idle" : "Manual compile", .secondary)
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

    // MARK: - Inspector

    private var inspectorSidebar: some View {
        VStack(spacing: 8) {
            Picker("Editor inspector", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch inspectorTab {
            case .parameters:
                parameterSidebar
            case .learn:
                metalGuide
            case .performance:
                performanceSidebar
            }
        }
        .padding(10)
    }

    private var parameterSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Parameters", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Text("Declared by // @param pragmas; sliders regenerate as you type. Values drive the running shader immediately.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                FormulaParamsEditor(cache: appModel.controlStateStore)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metalGuide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Metal, with GLSL instincts", systemImage: "book.pages")
                    .font(.headline)

                Text("The distance-estimator math transfers directly. Metal is a little stricter about types, function signatures, and memory address spaces, so the editor gives your DE a stable contract to plug into the renderer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Label("The useful mental model transfers", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Text("Folds, rotations, orbit traps, derivative tracking, distance bounds, and optimization reasoning are the same ideas. If you know how to write a GLSL DE, you already know most of the hard part.")
                        .font(.caption)
                }
                .padding(10)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

                metalDifferenceRow("GLSL", "Metal", "vec3 / mat3", "float3 / float3x3")
                metalDifferenceRow("uniforms", "Metal buffers", "uniform float radius", "fp.params[0]")
                metalDifferenceRow("inout", "thread reference", "inout Orbit orbit", "thread OrbitData& orbit")
                metalDifferenceRow("shader entry points", "DE contract", "main-style entry", "DE_Name_Dist + DE_Name")

                VStack(alignment: .leading, spacing: 6) {
                    Label("Keep the DE strict", systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                    Text("Use the exact signatures from the starter source. Keep parameters in FormulaParams, use float/float2/float3 consistently, and keep the distance-only and orbit-tracking variants mathematically aligned. The renderer can then specialize and optimize the hot loop safely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Fast porting checklist")
                        .font(.subheadline.weight(.semibold))
                    Text("• rename vecN → floatN and matN → floatNxN\n• move uniforms into fp.params[]\n• replace inout with thread T&\n• preserve a conservative distance bound\n• compile often; the last good shader stays live")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metalDifferenceRow(_ left: String, _ right: String, _ leftDetail: String, _ rightDetail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(left)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(leftDetail)
                    .font(.caption2.monospaced())
            }
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(right)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
                Text(rightDetail)
                    .font(.caption2.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.cyan.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var performanceSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Performance report", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.headline)
                    Spacer()
                    Text("MetricKit")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }

                Text("MetricKit automatically collects OS-level performance diagnostics in the background. This panel shows the latest local sample; submit it when you want to share structured performance data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Have a file to share too? Send the original Threshold file—such as .threshfx or .threshscene—through Files, AirDrop, or your normal feedback channel. Include the device, macOS version, active formula, and steps to reproduce; no performance-report file is needed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                performanceMetric("FPS", value: appModel.renderMetrics.fps > 0 ? String(format: "%.0f", appModel.renderMetrics.fps) : "—")
                performanceMetric("GPU frame", value: appModel.renderMetrics.gpuFrameMs > 0 ? String(format: "%.1f ms", appModel.renderMetrics.gpuFrameMs) : "—")
                performanceMetric("Avg steps / px", value: appModel.renderMetrics.avgStepsPerPixel > 0 ? String(format: "%.0f", appModel.renderMetrics.avgStepsPerPixel) : "—")
                performanceMetric("Hitches", value: "\(appModel.renderMetrics.hitchCount)")

                let report = appModel.makePerformanceReport()
                if report.findings.isEmpty {
                    Label("No obvious hotspot in this sample", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Focus areas")
                            .font(.subheadline.weight(.semibold))
                        ForEach(report.findings) { finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.title)
                                    .font(.caption.weight(.semibold))
                                Text(finding.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button {
                    submitReport()
                } label: {
                    Label("Submit report", systemImage: "arrow.up.circle")
                }
                .disabled(!UsageAnalytics.shared.analyticsEnabled)

                Text(UsageAnalytics.shared.analyticsEnabled
                     ? "Submission uses the anonymous analytics preference and includes only structured performance data."
                     : "Enable anonymous analytics in Settings to submit. MetricKit collection remains local while sharing is off.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let reportSubmissionStatus {
                    Text(reportSubmissionStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func performanceMetric(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 2)
    }

    private func submitReport() {
        reportSubmissionStatus = "Submitting…"
        let report = appModel.makePerformanceReport()
        Task { @MainActor in
            let result = await UsageAnalytics.shared.submitPerformanceReport(report)
            reportSubmissionStatus = switch result {
            case .submitted: "Report submitted. Thanks — the findings are ready to parse."
            case .sharingDisabled: "Anonymous analytics are off in Settings."
            case .unavailable: "CloudKit is unavailable right now."
            case .failed: "Submission failed; please try again later."
            }
        }
    }
}

#endif
