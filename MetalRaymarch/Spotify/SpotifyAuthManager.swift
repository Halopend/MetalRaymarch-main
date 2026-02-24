//
//  SpotifyAuthManager.swift
//  Threshold
//
//  OAuth 2.0 PKCE authentication for Spotify Web API.
//  No SDK dependency — uses ASWebAuthenticationSession + URLSession.
//

import Foundation
import AuthenticationServices
import CryptoKit

/// Manages Spotify OAuth 2.0 PKCE authentication flow and token lifecycle.
@MainActor
@Observable
class SpotifyAuthManager {
    
    // MARK: - Configuration
    
    /// Register your app at https://developer.spotify.com/dashboard
    /// Set the redirect URI to: Threshold://spotify-callback
    #warning("Replace YOUR_SPOTIFY_CLIENT_ID with your Spotify Developer Dashboard client ID")
    static let clientID = "YOUR_SPOTIFY_CLIENT_ID"
    static let redirectURI = "Threshold://spotify-callback"
    static let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing"
    ].joined(separator: " ")
    
    private static let authURL = "https://accounts.spotify.com/authorize"
    private static let tokenURL = "https://accounts.spotify.com/api/token"
    private static let keychainService = "com.Threshold.spotify"
    
    // MARK: - State
    
    private(set) var isAuthenticated: Bool = false
    private(set) var error: String?
    
    /// Current access token (short-lived, ~1 hour)
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    
    /// PKCE verifier for current auth flow
    private var codeVerifier: String?
    
    /// Retained reference to prevent premature deallocation
    private var authSession: ASWebAuthenticationSession?
    
    // MARK: - Initialization
    
    init() {
        loadTokensFromKeychain()
    }
    
    // MARK: - Public Interface
    
    /// Get a valid access token, refreshing if necessary.
    /// Returns nil if not authenticated.
    func getAccessToken() async -> String? {
        // If token is still valid (with 60s buffer), return it
        if let token = accessToken,
           let expiry = tokenExpiry,
           Date() < expiry.addingTimeInterval(-60) {
            return token
        }
        
        // Try to refresh
        if let refresh = refreshToken {
            do {
                try await refreshAccessToken(refreshToken: refresh)
                return accessToken
            } catch {
                self.error = "Token refresh failed: \(error.localizedDescription)"
                logout()
                return nil
            }
        }
        
        return nil
    }
    
    /// Start the OAuth PKCE login flow.
    func login() {
        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)
        
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        
        guard let url = components.url else {
            error = "Failed to construct auth URL"
            return
        }
        
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "Threshold"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.authSession = nil  // Release after completion
                
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        // User cancelled — not an error
                        return
                    }
                    self?.error = "Auth failed: \(error.localizedDescription)"
                    return
                }
                
                // The code exchange is handled via onOpenURL → handleCallback
                // Don't exchange here to avoid double-exchange race condition
            }
        }
        
        session.prefersEphemeralWebBrowserSession = false
        self.authSession = session  // Retain
        session.start()
    }
    
    /// Handle the OAuth callback URL (called from .onOpenURL)
    func handleCallback(_ url: URL) async {
        guard url.scheme == "Threshold",
              url.host == "spotify-callback" else { return }
        
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            error = "No authorization code in callback"
            return
        }
        
        await exchangeCodeForToken(code: code)
    }
    
    /// Clear all tokens and log out.
    func logout() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        isAuthenticated = false
        error = nil
        deleteTokensFromKeychain()
    }
    
    // MARK: - Token Exchange
    
    private func exchangeCodeForToken(code: String) async {
        guard let verifier = codeVerifier else {
            error = "Missing code verifier"
            return
        }
        
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": verifier
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Invalid response"
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                error = "Token exchange failed (\(httpResponse.statusCode)): \(body)"
                return
            }
            
            let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            applyTokenResponse(tokenResponse)
            codeVerifier = nil
            
        } catch {
            self.error = "Token exchange error: \(error.localizedDescription)"
        }
    }
    
    private func refreshAccessToken(refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpotifyError.tokenExpired
        }
        
        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        applyTokenResponse(tokenResponse)
    }
    
    private func applyTokenResponse(_ response: SpotifyTokenResponse) {
        accessToken = response.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        if let refresh = response.refreshToken {
            refreshToken = refresh
        }
        isAuthenticated = true
        error = nil
        saveTokensToKeychain()
    }
    
    // MARK: - PKCE Helpers
    
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(128)
            .description
    }
    
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - Keychain
    
    private func saveTokensToKeychain() {
        let tokens: [String: String?] = [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "token_expiry": tokenExpiry.map { String($0.timeIntervalSince1970) }
        ]
        guard let data = try? JSONEncoder().encode(tokens.compactMapValues { $0 }) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "tokens"
        ]
        
        SecItemDelete(query as CFDictionary)
        
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    private func loadTokensFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        
        accessToken = tokens["access_token"]
        refreshToken = tokens["refresh_token"]
        if let expiryStr = tokens["token_expiry"], let interval = Double(expiryStr) {
            tokenExpiry = Date(timeIntervalSince1970: interval)
        }
        
        // Check if we have valid tokens
        isAuthenticated = (refreshToken != nil)
    }
    
    private func deleteTokensFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "tokens"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
