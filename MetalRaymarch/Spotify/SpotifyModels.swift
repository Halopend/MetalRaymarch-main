//
//  SpotifyModels.swift
//  MetalRaymarch
//
//  Codable models for Spotify Web API responses.
//  Pure REST integration — no SDK dependency.
//

import Foundation

// MARK: - Authentication

struct SpotifyTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

// MARK: - Playback State

struct SpotifyPlaybackState: Codable {
    let isPlaying: Bool
    let progressMs: Int?
    let item: SpotifyTrack?
    let device: SpotifyDevice?
    let shuffleState: Bool?
    let repeatState: String?
    
    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
        case item
        case device
        case shuffleState = "shuffle_state"
        case repeatState = "repeat_state"
    }
}

struct SpotifyDevice: Codable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let volumePercent: Int?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case isActive = "is_active"
        case volumePercent = "volume_percent"
    }
}

// MARK: - Track

struct SpotifyTrack: Codable {
    let id: String
    let name: String
    let durationMs: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
    let uri: String
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case durationMs = "duration_ms"
        case artists, album, uri
    }
    
    var artistNames: String {
        artists.map(\.name).joined(separator: ", ")
    }
}

struct SpotifyArtist: Codable {
    let id: String
    let name: String
}

struct SpotifyAlbum: Codable {
    let id: String
    let name: String
    let images: [SpotifyImage]
    
    /// Largest album art image URL
    var artworkURL: URL? {
        images.first.flatMap { URL(string: $0.url) }
    }
    
    /// Smallest album art image (for thumbnails)
    var thumbnailURL: URL? {
        images.last.flatMap { URL(string: $0.url) }
    }
}

struct SpotifyImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

// MARK: - Audio Features (per-track summary)

struct SpotifyAudioFeatures: Codable {
    let id: String
    let energy: Float        // 0-1, intensity/activity
    let danceability: Float  // 0-1, rhythmic stability
    let valence: Float       // 0-1, musical positivity
    let tempo: Float         // BPM
    let loudness: Float      // dB (typically -60 to 0)
    let speechiness: Float   // 0-1, presence of spoken words
    let acousticness: Float  // 0-1, acoustic confidence
    let instrumentalness: Float // 0-1, no vocals confidence
    let liveness: Float      // 0-1, live audience presence
    let key: Int             // Pitch class (0=C, 1=C#, ... 11=B), -1 if unknown
    let mode: Int            // 0=minor, 1=major
    let timeSignature: Int   // beats per bar (3-7)
    
    enum CodingKeys: String, CodingKey {
        case id, energy, danceability, valence, tempo, loudness
        case speechiness, acousticness, instrumentalness, liveness
        case key, mode
        case timeSignature = "time_signature"
    }
    
    /// Normalized tempo (0-1) assuming range 60-200 BPM
    var normalizedTempo: Float {
        min(1.0, max(0.0, (tempo - 60.0) / 140.0))
    }
    
    /// Normalized loudness (0-1) from dB
    var normalizedLoudness: Float {
        min(1.0, max(0.0, (loudness + 60.0) / 60.0))
    }
}

// MARK: - Audio Analysis (detailed per-segment data)

struct SpotifyAudioAnalysis: Codable {
    let bars: [SpotifyTimeInterval]
    let beats: [SpotifyTimeInterval]
    let sections: [SpotifySection]
    let segments: [SpotifySegment]
    let tatums: [SpotifyTimeInterval]
    let track: SpotifyAnalysisTrack?
}

struct SpotifyAnalysisTrack: Codable {
    let duration: Float
    let tempo: Float
    let tempoConfidence: Float?
    let timeSignature: Int?
    let key: Int?
    let mode: Int?
    let loudness: Float?
    
    enum CodingKeys: String, CodingKey {
        case duration, tempo
        case tempoConfidence = "tempo_confidence"
        case timeSignature = "time_signature"
        case key, mode, loudness
    }
}

struct SpotifyTimeInterval: Codable {
    let start: Float
    let duration: Float
    let confidence: Float
}

struct SpotifySection: Codable {
    let start: Float
    let duration: Float
    let confidence: Float
    let loudness: Float
    let tempo: Float
    let key: Int
    let mode: Int
    let timeSignature: Int?
    
    enum CodingKeys: String, CodingKey {
        case start, duration, confidence, loudness, tempo, key, mode
        case timeSignature = "time_signature"
    }
}

struct SpotifySegment: Codable {
    let start: Float
    let duration: Float
    let confidence: Float
    let loudnessStart: Float
    let loudnessMax: Float
    let loudnessMaxTime: Float
    let loudnessEnd: Float?
    let pitches: [Float]      // 12 pitch classes (chroma), each 0-1
    let timbre: [Float]       // 12 timbre coefficients — [0]=loudness-like, [1]=brightness, [2]=flatness, ...
    
    enum CodingKeys: String, CodingKey {
        case start, duration, confidence
        case loudnessStart = "loudness_start"
        case loudnessMax = "loudness_max"
        case loudnessMaxTime = "loudness_max_time"
        case loudnessEnd = "loudness_end"
        case pitches, timbre
    }
    
    /// Approximate "bass energy" from timbre + pitch data
    /// Timbre[0] ≈ overall loudness, low pitches ≈ bass
    var bassEnergy: Float {
        let lowPitches = pitches.prefix(4).reduce(0, +) / 4.0  // C through E
        let loudnessComponent = min(1.0, max(0.0, (timbre.first ?? 0) / 200.0 + 0.5))
        return min(1.0, lowPitches * 0.6 + loudnessComponent * 0.4)
    }
    
    /// Approximate "mid energy" from timbre brightness
    var midEnergy: Float {
        let midPitches = pitches.dropFirst(4).prefix(4).reduce(0, +) / 4.0
        let brightness = timbre.count > 1 ? min(1.0, max(0.0, timbre[1] / 200.0 + 0.5)) : 0.5
        return min(1.0, midPitches * 0.5 + brightness * 0.5)
    }
    
    /// Approximate "treble energy" from high pitches and flatness
    var trebleEnergy: Float {
        let highPitches = pitches.suffix(4).reduce(0, +) / 4.0
        let flatness = timbre.count > 2 ? min(1.0, max(0.0, timbre[2] / 200.0 + 0.5)) : 0.5
        return min(1.0, highPitches * 0.5 + flatness * 0.5)
    }
}

// MARK: - Error Types

enum SpotifyError: LocalizedError, @unchecked Sendable {
    case notAuthenticated
    case tokenExpired
    case rateLimited(retryAfter: Int?)
    case apiError(statusCode: Int, message: String)
    case networkError(Error)
    case decodingError(Error)
    case noActiveDevice
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not connected to Spotify"
        case .tokenExpired: return "Spotify session expired"
        case .rateLimited(let retry): return "Rate limited\(retry.map { ", retry in \($0)s" } ?? "")"
        case .apiError(let code, let msg): return "Spotify API error \(code): \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingError(let err): return "Data error: \(err.localizedDescription)"
        case .noActiveDevice: return "No active Spotify device"
        }
    }
}
