//
//  SpotifyAPIClient.swift
//  MetalRaymarch
//
//  REST client for Spotify Web API endpoints.
//  Handles playback state, audio features, audio analysis, and transport controls.
//

import Foundation

/// Lightweight REST client for Spotify Web API.
/// All methods throw `SpotifyError` on failure.
actor SpotifyAPIClient {
    
    private let authManager: SpotifyAuthManager
    private let session = URLSession.shared
    private let baseURL = "https://api.spotify.com/v1"
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
    
    // Cache audio analysis per track ID (analysis doesn't change)
    private var analysisCache: [String: SpotifyAudioAnalysis] = [:]
    private var analysisCacheOrder: [String] = []  // FIFO insertion order
    private var featuresCache: [String: SpotifyAudioFeatures] = [:]
    private var featuresCacheOrder: [String] = []  // FIFO insertion order
    private let maxCacheSize = 20
    
    init(authManager: SpotifyAuthManager) {
        self.authManager = authManager
    }
    
    // MARK: - Playback State
    
    /// Get the current playback state (track, progress, device).
    /// Returns nil if nothing is playing.
    func getPlaybackState() async throws -> SpotifyPlaybackState? {
        let data = try await request("GET", path: "/me/player")
        // 204 = no content (nothing playing)
        guard !data.isEmpty else { return nil }
        return try decode(SpotifyPlaybackState.self, from: data)
    }
    
    /// Get currently playing track.
    func getCurrentTrack() async throws -> SpotifyTrack? {
        let state = try await getPlaybackState()
        return state?.item
    }
    
    // MARK: - Audio Features & Analysis
    
    /// Get audio features for a track (energy, tempo, danceability, etc).
    /// Results are cached per track ID.
    func getAudioFeatures(trackId: String) async throws -> SpotifyAudioFeatures {
        if let cached = featuresCache[trackId] { return cached }
        
        let data = try await request("GET", path: "/audio-features/\(trackId)")
        let features = try decode(SpotifyAudioFeatures.self, from: data)
        featuresCache[trackId] = features
        featuresCacheOrder.append(trackId)
        if featuresCacheOrder.count > maxCacheSize {
            let evict = featuresCacheOrder.removeFirst()
            featuresCache.removeValue(forKey: evict)
        }
        return features
    }
    
    /// Get detailed audio analysis for a track (beats, sections, segments with pitch/timbre).
    /// Results are cached per track ID.
    func getAudioAnalysis(trackId: String) async throws -> SpotifyAudioAnalysis {
        if let cached = analysisCache[trackId] { return cached }
        
        let data = try await request("GET", path: "/audio-analysis/\(trackId)")
        let analysis = try decode(SpotifyAudioAnalysis.self, from: data)
        analysisCache[trackId] = analysis
        analysisCacheOrder.append(trackId)
        
        // Trim cache FIFO
        if analysisCacheOrder.count > maxCacheSize {
            let evict = analysisCacheOrder.removeFirst()
            analysisCache.removeValue(forKey: evict)
        }
        
        return analysis
    }
    
    // MARK: - Transport Controls
    
    /// Resume playback on the active device.
    func play() async throws {
        _ = try await request("PUT", path: "/me/player/play")
    }
    
    /// Pause playback.
    func pause() async throws {
        _ = try await request("PUT", path: "/me/player/pause")
    }
    
    /// Skip to next track.
    func next() async throws {
        _ = try await request("POST", path: "/me/player/next")
    }
    
    /// Skip to previous track.
    func previous() async throws {
        _ = try await request("POST", path: "/me/player/previous")
    }
    
    /// Seek to position in current track.
    func seek(positionMs: Int) async throws {
        _ = try await request("PUT", path: "/me/player/seek?position_ms=\(positionMs)")
    }
    
    /// Clear caches (e.g., on logout).
    func clearCaches() {
        analysisCache.removeAll()
        analysisCacheOrder.removeAll()
        featuresCache.removeAll()
        featuresCacheOrder.removeAll()
    }
    
    // MARK: - HTTP Layer
    
    private func request(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        guard let token = await authManager.getAccessToken() else {
            throw SpotifyError.notAuthenticated
        }
        
        guard let url = URL(string: baseURL + path) else {
            throw SpotifyError.apiError(statusCode: 0, message: "Invalid URL: \(path)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpotifyError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyError.apiError(statusCode: 0, message: "Non-HTTP response")
        }
        
        switch httpResponse.statusCode {
        case 204:
            return Data()  // No content (valid for some endpoints like play/pause)
        case 200...299:
            return data
        case 401:
            throw SpotifyError.tokenExpired
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw SpotifyError.rateLimited(retryAfter: retryAfter)
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SpotifyError.apiError(statusCode: httpResponse.statusCode, message: message)
        }
    }
    
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SpotifyError.decodingError(error)
        }
    }
}
