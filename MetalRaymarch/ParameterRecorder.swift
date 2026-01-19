//
//  ParameterRecorder.swift
//  MetalRaymarch
//
//  Created on January 18, 2026.
//  Efficient parameter recording system for playback and preset animation.
//

import Foundation
import simd

// MARK: - Recorded Parameter Frame

/// A single frame of recorded parameter data with timestamp
struct ParameterFrame: Codable {
    let timestamp: Float  // Time in seconds from recording start
    
    // Position and scale
    let position: SIMD3<Float>
    let scale: Float
    
    // Mandelbox parameters
    let minDistance: Float
    let fractalScale: Float
    let foldingLimit: Float
    let sphereRadius: Float
    
    // Visual parameters
    let colorMix: Float
    let glowIntensity: Float
    let colorIterations: Float
}

// MARK: - Recording Session

/// A complete recording session containing multiple frames
struct ParameterRecording: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    let duration: Float
    let frameCount: Int
    let frames: [ParameterFrame]
    var thumbnailData: Data?
    
    /// Target FPS for recording (actual may vary based on performance)
    static let targetFPS: Float = 30.0
    
    /// Interpolate parameters at a given time
    func interpolatedFrame(at time: Float) -> ParameterFrame? {
        guard !frames.isEmpty else { return nil }
        
        // Clamp time to valid range
        let clampedTime = max(0, min(duration, time))
        
        // Find surrounding frames
        var lowerIndex = 0
        var upperIndex = frames.count - 1
        
        for (index, frame) in frames.enumerated() {
            if frame.timestamp <= clampedTime {
                lowerIndex = index
            }
            if frame.timestamp >= clampedTime {
                upperIndex = index
                break
            }
        }
        
        // If same frame, return it
        if lowerIndex == upperIndex {
            return frames[lowerIndex]
        }
        
        // Interpolate between frames
        let lower = frames[lowerIndex]
        let upper = frames[upperIndex]
        let t = (clampedTime - lower.timestamp) / (upper.timestamp - lower.timestamp)
        
        return ParameterFrame(
            timestamp: clampedTime,
            position: simd_mix(lower.position, upper.position, SIMD3<Float>(repeating: t)),
            scale: simd_mix(lower.scale, upper.scale, t),
            minDistance: simd_mix(lower.minDistance, upper.minDistance, t),
            fractalScale: simd_mix(lower.fractalScale, upper.fractalScale, t),
            foldingLimit: simd_mix(lower.foldingLimit, upper.foldingLimit, t),
            sphereRadius: simd_mix(lower.sphereRadius, upper.sphereRadius, t),
            colorMix: simd_mix(lower.colorMix, upper.colorMix, t),
            glowIntensity: simd_mix(lower.glowIntensity, upper.glowIntensity, t),
            colorIterations: simd_mix(lower.colorIterations, upper.colorIterations, t)
        )
    }
}

// MARK: - Recording State

enum RecordingState {
    case idle
    case recording
    case playing
    case paused
}

// MARK: - Parameter Recorder

/// Records and plays back parameter changes over time
@MainActor
@Observable
class ParameterRecorder {
    // Current state
    private(set) var state: RecordingState = .idle
    private(set) var currentRecording: ParameterRecording?
    private(set) var recordings: [ParameterRecording] = []
    
    // Recording state
    private var recordingFrames: [ParameterFrame] = []
    private var recordingStartTime: Date?
    private var lastRecordTime: Float = 0
    
    // Playback state
    private(set) var playbackTime: Float = 0
    private(set) var playbackDuration: Float = 0
    private var playbackLoop: Bool = true
    
    // Settings reference
    private weak var renderSettings: RenderSettings?
    
    // Recording interval (minimum time between frames to avoid excessive data)
    private let minFrameInterval: Float = 1.0 / ParameterRecording.targetFPS
    
    // Storage
    private let recordingsKey = "ParameterRecordings"
    
    private var recordingsDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsPath = documentsPath.appendingPathComponent("ParameterRecordings", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: recordingsPath.path) {
            try? FileManager.default.createDirectory(at: recordingsPath, withIntermediateDirectories: true)
        }
        
        return recordingsPath
    }
    
    private var recordingsFileURL: URL {
        recordingsDirectory.appendingPathComponent("recordings.json")
    }
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
        loadRecordings()
    }
    
    // MARK: - Recording
    
    /// Start recording parameters
    func startRecording() {
        guard state == .idle else { return }
        
        state = .recording
        recordingFrames = []
        recordingStartTime = Date()
        lastRecordTime = -minFrameInterval  // Ensure first frame is captured
        
        // Capture initial frame immediately
        captureFrame()
        
        print("🔴 Recording started")
    }
    
    /// Stop recording and create a ParameterRecording
    func stopRecording() -> ParameterRecording? {
        guard state == .recording else { return nil }
        
        state = .idle
        
        guard !recordingFrames.isEmpty else {
            print("⚠️ No frames recorded")
            return nil
        }
        
        let duration = recordingFrames.last?.timestamp ?? 0
        let recording = ParameterRecording(
            id: UUID(),
            name: RandomNameGenerator.generate(),
            createdAt: Date(),
            duration: duration,
            frameCount: recordingFrames.count,
            frames: recordingFrames,
            thumbnailData: nil
        )
        
        currentRecording = recording
        recordings.insert(recording, at: 0)
        saveRecordings()
        
        print("⏹️ Recording stopped: \(recordingFrames.count) frames, \(String(format: "%.1f", duration))s")
        
        recordingFrames = []
        recordingStartTime = nil
        
        return recording
    }
    
    /// Called every frame during recording to capture parameter state
    func update() {
        guard state == .recording,
              let startTime = recordingStartTime,
              let settings = renderSettings else { return }
        
        let currentTime = Float(Date().timeIntervalSince(startTime))
        
        // Only capture if enough time has passed
        if currentTime - lastRecordTime >= minFrameInterval {
            captureFrame()
            lastRecordTime = currentTime
        }
    }
    
    private func captureFrame() {
        guard let settings = renderSettings,
              let startTime = recordingStartTime else { return }
        
        let timestamp = Float(Date().timeIntervalSince(startTime))
        
        let frame = ParameterFrame(
            timestamp: timestamp,
            position: settings.position,
            scale: settings.scale,
            minDistance: settings.minDistance,
            fractalScale: settings.fractalScale,
            foldingLimit: settings.foldingLimit,
            sphereRadius: settings.sphereRadius,
            colorMix: settings.colorMix,
            glowIntensity: settings.glowIntensity,
            colorIterations: settings.colorIterations
        )
        
        recordingFrames.append(frame)
    }
    
    // MARK: - Playback
    
    /// Start playing a recording
    func startPlayback(_ recording: ParameterRecording, loop: Bool = true) {
        guard state == .idle else { return }
        
        currentRecording = recording
        playbackTime = 0
        playbackDuration = recording.duration
        playbackLoop = loop
        state = .playing
        
        print("▶️ Playback started: \(recording.name)")
    }
    
    /// Pause playback
    func pausePlayback() {
        guard state == .playing else { return }
        state = .paused
        print("⏸️ Playback paused")
    }
    
    /// Resume playback
    func resumePlayback() {
        guard state == .paused else { return }
        state = .playing
        print("▶️ Playback resumed")
    }
    
    /// Stop playback
    func stopPlayback() {
        guard state == .playing || state == .paused else { return }
        state = .idle
        currentRecording = nil
        playbackTime = 0
        print("⏹️ Playback stopped")
    }
    
    /// Update playback and apply parameters
    func updatePlayback(deltaTime: Float) {
        guard state == .playing,
              let recording = currentRecording,
              let settings = renderSettings else { return }
        
        playbackTime += deltaTime
        
        // Handle looping or stopping
        if playbackTime >= recording.duration {
            if playbackLoop {
                playbackTime = playbackTime.truncatingRemainder(dividingBy: recording.duration)
            } else {
                stopPlayback()
                return
            }
        }
        
        // Get interpolated frame and apply to settings
        if let frame = recording.interpolatedFrame(at: playbackTime) {
            settings.targetPosition = frame.position
            settings.targetMinDistance = frame.minDistance
            settings.targetFoldingLimit = frame.foldingLimit
            settings.targetSphereRadius = frame.sphereRadius
            settings.fractalScale = frame.fractalScale
            settings.colorMix = frame.colorMix
            settings.glowIntensity = frame.glowIntensity
            settings.colorIterations = frame.colorIterations
        }
    }
    
    // MARK: - Storage
    
    private func loadRecordings() {
        let fileURL = recordingsFileURL
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            recordings = []
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recordings = try decoder.decode([ParameterRecording].self, from: data)
            recordings.sort { $0.createdAt > $1.createdAt }
        } catch {
            print("Failed to load recordings: \(error)")
            recordings = []
        }
    }
    
    private func saveRecordings() {
        let fileURL = recordingsFileURL
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(recordings)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save recordings: \(error)")
        }
    }
    
    /// Delete a recording
    func deleteRecording(_ recording: ParameterRecording) {
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }
    
    /// Rename a recording
    func renameRecording(_ recording: ParameterRecording, to newName: String) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index].name = newName
        saveRecordings()
    }
    
    /// Update recording thumbnail
    func updateThumbnail(_ recording: ParameterRecording, thumbnailData: Data?) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index].thumbnailData = thumbnailData
        saveRecordings()
    }
    
    // MARK: - Computed Properties
    
    var isRecording: Bool { state == .recording }
    var isPlaying: Bool { state == .playing }
    var isPaused: Bool { state == .paused }
    var isIdle: Bool { state == .idle }
    
    var recordingDuration: Float {
        guard state == .recording, let startTime = recordingStartTime else { return 0 }
        return Float(Date().timeIntervalSince(startTime))
    }
    
    var playbackProgress: Float {
        guard playbackDuration > 0 else { return 0 }
        return playbackTime / playbackDuration
    }
}

// MARK: - Random Name Generator

/// Generates creative random names for recordings and presets
struct RandomNameGenerator {
    
    // Word lists for generating unique names
    private static let adjectives = [
        // Colors
        "Crimson", "Azure", "Golden", "Silver", "Emerald", "Violet", "Amber", "Coral",
        "Obsidian", "Ivory", "Sapphire", "Ruby", "Jade", "Onyx", "Pearl", "Copper",
        
        // Cosmic
        "Stellar", "Cosmic", "Nebula", "Astral", "Lunar", "Solar", "Orbital", "Quantum",
        "Photon", "Plasma", "Void", "Nova", "Eclipse", "Aurora", "Zenith", "Apex",
        
        // Nature
        "Crystal", "Frozen", "Molten", "Ancient", "Eternal", "Silent", "Mystic", "Sacred",
        "Primal", "Wild", "Serene", "Radiant", "Twilight", "Dawn", "Midnight", "Shadow",
        
        // Abstract
        "Hidden", "Lost", "Infinite", "Fractal", "Spiral", "Recursive", "Folded", "Warped",
        "Twisted", "Shattered", "Woven", "Dancing", "Floating", "Drifting", "Flowing", "Pulsing"
    ]
    
    private static let nouns = [
        // Geometric
        "Vortex", "Nexus", "Portal", "Prism", "Helix", "Matrix", "Lattice", "Grid",
        "Tesseract", "Polygon", "Fractal", "Spiral", "Cascade", "Array", "Mesh", "Web",
        
        // Cosmic
        "Nebula", "Galaxy", "Cosmos", "Dimension", "Realm", "Domain", "Horizon", "Expanse",
        "Abyss", "Void", "Rift", "Storm", "Wave", "Pulse", "Burst", "Flux",
        
        // Nature
        "Forest", "Mountain", "Ocean", "Valley", "Canyon", "Cave", "Cavern", "Peak",
        "Glacier", "Volcano", "Island", "Shore", "Reef", "Garden", "Sanctuary", "Haven",
        
        // Abstract
        "Dream", "Vision", "Echo", "Whisper", "Memory", "Moment", "Journey", "Path",
        "Gate", "Bridge", "Threshold", "Origin", "Genesis", "Enigma", "Mystery", "Wonder"
    ]
    
    private static let suffixes = [
        // Numbers/IDs
        "Alpha", "Beta", "Gamma", "Delta", "Omega", "Prime", "Zero", "One",
        "Mk-I", "Mk-II", "Mk-III", "V1", "V2", "X", "Neo", "Ultra"
    ]
    
    /// Generate a random creative name
    static func generate() -> String {
        let adjective = adjectives.randomElement()!
        let noun = nouns.randomElement()!
        
        // 30% chance to add a suffix
        if Int.random(in: 0..<10) < 3 {
            let suffix = suffixes.randomElement()!
            return "\(adjective) \(noun) \(suffix)"
        }
        
        return "\(adjective) \(noun)"
    }
    
    /// Generate a random name with a specific prefix
    static func generate(prefix: String) -> String {
        let noun = nouns.randomElement()!
        return "\(prefix) \(noun)"
    }
    
    /// Generate a simple numbered name
    static func generateNumbered(base: String, count: Int) -> String {
        return "\(base) #\(count + 1)"
    }
}

// MARK: - SIMD3 Codable Extension

extension SIMD3: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        self.init(x: x, y: y, z: z)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}
