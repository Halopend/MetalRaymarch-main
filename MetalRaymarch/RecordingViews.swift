//
//  RecordingViews.swift
//  MetalRaymarch
//
//  Created on January 18, 2026.
//  Recording indicator and playback UI components.
//

import SwiftUI

// MARK: - Recording Indicator View

/// Apple-style recording indicator shown at top center of view
struct RecordingIndicatorView: View {
    let recorder: ParameterRecorder
    
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Recording dot with pulsing animation
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .shadow(color: .red.opacity(0.6), radius: isPulsing ? 8 : 4)
                .scaleEffect(isPulsing ? 1.1 : 1.0)
            
            // Recording time
            Text(formatTime(recorder.recordingDuration))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
    }
    
    private func formatTime(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, ms)
    }
}

// MARK: - Playback Indicator View

/// Playback indicator shown during recording playback
struct PlaybackIndicatorView: View {
    let recorder: ParameterRecorder
    let onStop: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause button
            Button {
                if recorder.isPlaying {
                    recorder.pausePlayback()
                } else if recorder.isPaused {
                    recorder.resumePlayback()
                }
            } label: {
                Image(systemName: recorder.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.blue.opacity(0.8)))
            }
            .buttonStyle(.plain)
            
            // Progress bar
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.3))
                            .frame(height: 4)
                        
                        // Progress fill
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue)
                            .frame(width: geometry.size.width * CGFloat(recorder.playbackProgress), height: 4)
                    }
                }
                .frame(height: 4)
                
                // Time display
                HStack {
                    Text(formatTime(recorder.playbackTime))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    
                    Spacer()
                    
                    Text(formatTime(recorder.playbackDuration))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 120)
            
            // Stop button
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.red.opacity(0.8)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.blue.opacity(0.5), lineWidth: 1)
                )
        )
    }
    
    private func formatTime(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Recordings List View

/// List view for managing recorded parameter animations
struct RecordingsListView: View {
    @Environment(\.dismiss) private var dismiss
    
    let recorder: ParameterRecorder
    let onPlay: (ParameterRecording) -> Void
    
    @State private var searchText = ""
    @State private var recordingToRename: ParameterRecording?
    @State private var newName = ""
    
    var filteredRecordings: [ParameterRecording] {
        if searchText.isEmpty {
            return recorder.recordings
        }
        return recorder.recordings.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if recorder.recordings.isEmpty {
                    emptyStateView
                } else {
                    recordingsList
                }
            }
            .navigationTitle("Recordings")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search recordings")
            .alert("Rename Recording", isPresented: .init(
                get: { recordingToRename != nil },
                set: { if !$0 { recordingToRename = nil } }
            )) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {
                    recordingToRename = nil
                }
                Button("Rename") {
                    if let recording = recordingToRename {
                        recorder.renameRecording(recording, to: newName)
                    }
                    recordingToRename = nil
                }
            } message: {
                Text("Enter a new name for the recording")
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("No Recordings Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Make a fist with your left hand to start recording your parameter changes")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding()
    }
    
    private var recordingsList: some View {
        List {
            ForEach(filteredRecordings) { recording in
                RecordingRowView(
                    recording: recording,
                    onPlay: {
                        onPlay(recording)
                        dismiss()
                    },
                    onDelete: {
                        recorder.deleteRecording(recording)
                    },
                    onRename: {
                        newName = recording.name
                        recordingToRename = recording
                    }
                )
            }
        }
    }
}

// MARK: - Recording Row View

struct RecordingRowView: View {
    let recording: ParameterRecording
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            Group {
                #if os(visionOS) || os(iOS)
                if let data = recording.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholderThumbnail
                }
                #elseif os(macOS)
                if let data = recording.thumbnailData, let image = NSImage(data: data) {
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
                Text(recording.name)
                    .font(.headline)
                
                HStack(spacing: 8) {
                    // Duration badge
                    Label(formatDuration(recording.duration), systemImage: "clock")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(Capsule())
                    
                    // Frame count
                    Text("\(recording.frameCount) frames")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(recording.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Play button
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onPlay() }
        .contextMenu {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete '\(recording.name)'? This cannot be undone.")
        }
    }
    
    private var placeholderThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60)
            
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
    
    private func formatDuration(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Recording Button (for main UI)

struct RecordingButton: View {
    let recorder: ParameterRecorder
    let onPlayRecording: (ParameterRecording) -> Void
    
    @State private var showRecordingsList = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Recordings list button
            Button {
                showRecordingsList = true
            } label: {
                Label("Recordings", systemImage: "waveform")
            }
            
            // Recording count badge
            if !recorder.recordings.isEmpty {
                Text("\(recorder.recordings.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .sheet(isPresented: $showRecordingsList) {
            RecordingsListView(
                recorder: recorder,
                onPlay: onPlayRecording
            )
        }
    }
}

// MARK: - Preview

#Preview("Recording Indicator") {
    VStack(spacing: 20) {
        RecordingIndicatorView(recorder: PreviewRecorder.recording)
        PlaybackIndicatorView(recorder: PreviewRecorder.playing) { }
    }
    .padding(50)
    .background(Color.black.opacity(0.8))
}

// Preview helper
private enum PreviewRecorder {
    @MainActor
    static var recording: ParameterRecorder {
        let recorder = ParameterRecorder(renderSettings: RenderSettings())
        return recorder
    }
    
    @MainActor
    static var playing: ParameterRecorder {
        let recorder = ParameterRecorder(renderSettings: RenderSettings())
        return recorder
    }
}
