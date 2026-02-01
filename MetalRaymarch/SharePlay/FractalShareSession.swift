//
//  FractalShareSession.swift
//  MetalRaymarch
//
//  Manages SharePlay sessions for synchronized fractal exploration.
//  Handles session lifecycle, role management, and state synchronization.
//

import GroupActivities
import Combine
import Foundation
import os

/// Role in the SharePlay session
enum SharePlayRole: String, CaseIterable {
    case driver = "Driver"      // Controls the fractal, others follow
    case viewer = "Viewer"      // Follows the driver's view
    case collaborative = "Collaborative"  // Everyone can control (last-write-wins)
}

/// Connection state for the SharePlay session
enum SharePlayState {
    case inactive           // No session
    case waiting            // Activity started, waiting for others
    case connected(Int)     // Connected with N participants
    case error(String)      // Error occurred
}

/// Manages SharePlay sessions for fractal synchronization
@MainActor
@Observable
class FractalShareSession {
    
    // MARK: - Public Properties
    
    /// Current session state
    private(set) var state: SharePlayState = .inactive
    
    /// Our role in the session
    var role: SharePlayRole = .collaborative
    
    /// Whether we're the session owner (started the activity)
    private(set) var isOwner: Bool = false
    
    /// Number of connected participants
    private(set) var participantCount: Int = 0
    
    /// Our unique ID for this session
    let localID = UUID()
    
    /// Last received message timestamp (for detecting stale state)
    private(set) var lastReceivedTimestamp: TimeInterval = 0
    
    // MARK: - Private Properties
    
    private var groupSession: GroupSession<FractalShareActivity>?
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var tasks = Set<Task<Void, Never>>()
    
    private weak var renderSettings: RenderSettings?
    
    // Rate limiting: don't send more than ~30 updates per second
    private var lastSendTime: TimeInterval = 0
    private let minSendInterval: TimeInterval = 1.0 / 30.0
    
    private let logger = Logger(subsystem: "com.puppypower.MetalRaymarch", category: "SharePlay")
    
    // MARK: - Initialization
    
    init(renderSettings: RenderSettings) {
        self.renderSettings = renderSettings
    }
    
    deinit {
        // Tasks will be cancelled when the set is deallocated
        for task in tasks {
            task.cancel()
        }
    }
    
    // MARK: - Public Methods
    
    /// Start a new SharePlay activity
    func startSharing() async {
        let activity = FractalShareActivity()
        
        do {
            // This will prompt user to start FaceTime if not in a call
            let result = try await activity.activate()
            
            if result {
                logger.info("SharePlay activity activated successfully")
                isOwner = true
                state = .waiting
                // Track for analytics
                UsageAnalytics.shared.trackSharePlayUsed()
            } else {
                logger.warning("SharePlay activity activation returned false")
                state = .error("Could not start sharing")
            }
        } catch {
            logger.error("Failed to activate SharePlay: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
        }
    }
    
    /// Stop sharing and leave the session
    func stopSharing() {
        logger.info("Stopping SharePlay session")
        
        groupSession?.leave()
        groupSession = nil
        messenger = nil
        
        subscriptions.removeAll()
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        
        state = .inactive
        isOwner = false
        participantCount = 0
    }
    
    /// Configure session handling (call once at app startup)
    func configureGroupSessions() {
        let task = Task {
            for await session in FractalShareActivity.sessions() {
                await handleNewSession(session)
            }
        }
        tasks.insert(task)
    }
    
    /// Send current state to other participants (call from render loop or gesture handler)
    func sendStateUpdate() {
        guard let messenger = messenger,
              let settings = renderSettings,
              role != .viewer else { return }
        
        // Rate limit
        let now = Date().timeIntervalSince1970
        guard now - lastSendTime >= minSendInterval else { return }
        lastSendTime = now
        
        let message = FractalSyncMessage(from: settings, senderID: localID)
        
        Task {
            do {
                try await messenger.send(message)
            } catch {
                logger.error("Failed to send state update: \(error.localizedDescription)")
            }
        }
    }
    
    /// Force send immediately (for important state changes like fractal type)
    func sendStateUpdateImmediate() {
        guard let messenger = messenger,
              let settings = renderSettings,
              role != .viewer else { return }
        
        lastSendTime = Date().timeIntervalSince1970
        
        let message = FractalSyncMessage(from: settings, senderID: localID)
        
        Task {
            do {
                try await messenger.send(message)
            } catch {
                logger.error("Failed to send immediate state update: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func handleNewSession(_ session: GroupSession<FractalShareActivity>) async {
        logger.info("New SharePlay session received")
        
        // Clean up any existing session
        stopSharing()
        
        self.groupSession = session
        
        // Create messenger for sending/receiving state
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger
        
        // Subscribe to session state changes
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessionState in
                self?.handleSessionStateChange(sessionState)
            }
            .store(in: &subscriptions)
        
        // Subscribe to participant changes
        session.$activeParticipants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in
                self?.participantCount = participants.count
                if participants.count > 0 {
                    self?.state = .connected(participants.count)
                }
                self?.logger.info("Participants updated: \(participants.count)")
            }
            .store(in: &subscriptions)
        
        // Start receiving messages
        let receiveTask = Task { [weak self] in
            guard let self = self else { return }
            
            for await (message, _) in messenger.messages(of: FractalSyncMessage.self) {
                await self.handleReceivedMessage(message)
            }
        }
        tasks.insert(receiveTask)
        
        // Join the session
        session.join()
        state = .waiting
    }
    
    private func handleSessionStateChange(_ sessionState: GroupSession<FractalShareActivity>.State) {
        switch sessionState {
        case .waiting:
            state = .waiting
            logger.info("Session state: waiting")
            
        case .joined:
            state = .connected(participantCount)
            logger.info("Session state: joined")
            
        case .invalidated(let reason):
            state = .error("Session ended: \(reason)")
            logger.info("Session state: invalidated - \(reason)")
            stopSharing()
            
        @unknown default:
            logger.warning("Unknown session state")
        }
    }
    
    private func handleReceivedMessage(_ message: FractalSyncMessage) async {
        // Don't process our own messages
        guard message.senderID != localID else { return }
        
        // Don't process old messages
        guard message.timestamp > lastReceivedTimestamp else { return }
        lastReceivedTimestamp = message.timestamp
        
        // In viewer mode or collaborative mode, apply the state
        if role == .viewer || role == .collaborative {
            if let settings = renderSettings {
                message.apply(to: settings)
            }
        }
    }
}

// MARK: - SharePlay Eligibility Check

extension FractalShareSession {
    
    /// Check if SharePlay is available on this device
    static var isSharePlayAvailable: Bool {
        // SharePlay requires iOS 15+ / visionOS 1+
        return true
    }
}
