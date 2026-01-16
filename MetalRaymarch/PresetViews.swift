//
//  PresetViews.swift
//  MetalProject
//
//  Created on January 11, 2026.
//

import SwiftUI

// MARK: - Preset Row View
struct PresetRowView: View {
    let preset: FractalPreset
    let onLoad: () -> Void
    let onDelete: () -> Void
    let onRate: (Int) -> Void
    let onExport: () -> Void
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            Group {
                #if os(visionOS) || os(iOS)
                if let image = preset.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholderThumbnail
                }
                #elseif os(macOS)
                if let image = preset.thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholderThumbnail
                }
                #endif
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name)
                    .font(.headline)
                
                HStack(spacing: 8) {
                    Text("Mandelbox")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(Capsule())
                    
                    Text(preset.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Rating
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            let newValue = (preset.rating == value) ? 0 : value
                            onRate(newValue)
                        } label: {
                            Image(systemName: value <= preset.rating ? "star.fill" : "star")
                                .foregroundStyle(value <= preset.rating ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Set rating")
                    }
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 12) {
                Button(action: onExport) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Export preset")

                Menu {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .padding(6)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .help("More actions")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onLoad() }
        .confirmationDialog("Delete Preset?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete '\(preset.name)'? This cannot be undone.")
        }
    }
    
    private var placeholderThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60)
            
            Image(systemName: "cube.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Save Preset Sheet
struct SavePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let settings: RenderSettings
    let presetManager: PresetManager
    let thumbnailData: Data?
    let onSave: (String) -> Void
    
    @State private var presetName: String = ""
    @State private var showError = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Preview thumbnail
                Group {
                    #if os(visionOS) || os(iOS)
                    if let data = thumbnailData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        placeholderImage
                    }
                    #elseif os(macOS)
                    if let data = thumbnailData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        placeholderImage
                    }
                    #endif
                }
                
                // Name input
                TextField("Preset Name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Save Preset")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePreset()
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please enter a name for the preset.")
            }
        }
    }
    
    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 150)
            
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                Text("No preview available")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
    
    private func savePreset() {
        let trimmedName = presetName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            showError = true
            return
        }
        
        onSave(trimmedName)
        dismiss()
    }
}

// MARK: - Presets List View
struct PresetsListView: View {
    @Environment(\.dismiss) private var dismiss
    
    let presetManager: PresetManager
    let settings: RenderSettings
    let onLoadPreset: (FractalPreset) -> Void
    
    @State private var searchText = ""
    @State private var showSaveSheet = false
    @State private var currentThumbnailData: Data?
    @State private var presetToRename: FractalPreset?
    @State private var newName: String = ""
    @State private var shareItem: ShareItem?
    
    var filteredPresets: [FractalPreset] {
        let base: [FractalPreset]
        if searchText.isEmpty {
            base = presetManager.presets
        } else {
            base = presetManager.presets.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        // Favorites (higher rating) float to top, then newest
        return base.sorted { lhs, rhs in
            if lhs.rating != rhs.rating {
                return lhs.rating > rhs.rating
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if presetManager.presets.isEmpty {
                    emptyStateView
                } else {
                    presetsList
                }
            }
            .navigationTitle("Presets")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSaveSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search presets")
            .sheet(isPresented: $showSaveSheet) {
                SavePresetSheet(
                    settings: settings,
                    presetManager: presetManager,
                    thumbnailData: currentThumbnailData
                ) { name in
                    presetManager.savePreset(name: name, settings: settings, thumbnailData: currentThumbnailData)
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .alert("Rename Preset", isPresented: .init(
                get: { presetToRename != nil },
                set: { if !$0 { presetToRename = nil } }
            )) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {
                    presetToRename = nil
                }
                Button("Rename") {
                    if let preset = presetToRename {
                        presetManager.renamePreset(preset, to: newName)
                    }
                    presetToRename = nil
                }
            } message: {
                Text("Enter a new name for the preset")
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("No Presets Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Save your current settings to create a preset")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                showSaveSheet = true
            } label: {
                Label("Save Current Settings", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
    }
    
    private var presetsList: some View {
        List {
            ForEach(filteredPresets) { preset in
                PresetRowView(
                    preset: preset,
                    onLoad: {
                        onLoadPreset(preset)
                        dismiss()
                    },
                    onDelete: {
                        presetManager.deletePreset(preset)
                    },
                    onRate: { rating in
                        presetManager.updateRating(preset, rating: rating)
                    },
                    onExport: {
                        if let url = presetManager.exportPreset(preset) {
                            shareItem = ShareItem(url: url)
                        }
                    }
                )
                .contextMenu {
                    Button {
                        onLoadPreset(preset)
                        dismiss()
                    } label: {
                        Label("Load", systemImage: "arrow.down.circle")
                    }
                    
                    Button {
                        newName = preset.name
                        presetToRename = preset
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        if let url = presetManager.exportPreset(preset) {
                            shareItem = ShareItem(url: url)
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// MARK: - Compact Preset Button (for main UI)
struct PresetButton: View {
    let presetManager: PresetManager
    let settings: RenderSettings
    let captureScreenshot: () async -> Data?
    let onLoadPreset: (FractalPreset) -> Void
    
    @State private var showPresetsList = false
    @State private var showQuickSave = false
    @State private var quickSaveName = ""
    @State private var capturedThumbnail: Data?
    
    var body: some View {
        HStack(spacing: 8) {
            // Presets button
            Button {
                showPresetsList = true
            } label: {
                Label("Presets", systemImage: "folder")
            }
            
            // Quick save button
            Button {
                Task {
                    capturedThumbnail = await captureScreenshot()
                    quickSaveName = "Preset \(presetManager.presets.count + 1)"
                    showQuickSave = true
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Quick save current settings")
        }
        .sheet(isPresented: $showPresetsList) {
            PresetsListView(
                presetManager: presetManager,
                settings: settings,
                onLoadPreset: onLoadPreset
            )
        }
        .sheet(isPresented: $showQuickSave) {
            SavePresetSheet(
                settings: settings,
                presetManager: presetManager,
                thumbnailData: capturedThumbnail
            ) { name in
                presetManager.savePreset(name: name, settings: settings, thumbnailData: capturedThumbnail)
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Sharing helper
#if os(iOS) || os(visionOS)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
struct ShareSheet: NSViewControllerRepresentable {
    let activityItems: [Any]

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        let picker = NSSharingServicePicker(items: activityItems)
        DispatchQueue.main.async {
            picker.show(relativeTo: .zero, of: controller.view, preferredEdge: .minY)
        }
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}
#endif

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Preview
#Preview {
    let presetManager = PresetManager()
    let settings = RenderSettings()
    
    return PresetsListView(
        presetManager: presetManager,
        settings: settings,
        onLoadPreset: { _ in }
    )
}
