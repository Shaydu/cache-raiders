import Foundation
import Combine

// MARK: - WebSocket Service
// Note: Socket.IO requires a specific client library for full protocol support.
// This service provides basic connection status tracking.
// For full Socket.IO support, consider adding Socket.IO-Client-Swift library.
class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    @Published var isConnected: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
        
        var displayName: String {
            switch self {
            case .disconnected:
                return "Disconnected"
            case .connecting:
                return "Connecting..."
            case .connected:
                return "Connected"
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }
    
    // Socket.IO handshake state
    private enum HandshakeState: Equatable {
        case notStarted
        case waitingForSessionInfo  // Waiting for "0" packet with session info
        case waitingForNamespaceConfirmation  // Sent "40", waiting for "40" response
        case completed
    }
    private var handshakeState: HandshakeState = .notStarted
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var healthCheckTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private let reconnectInterval: TimeInterval = 5.0
    private let pingInterval: TimeInterval = 30.0
    private let healthCheckInterval: TimeInterval = 10.0
    private let connectionTimeoutInterval: TimeInterval = 30.0 // Increased timeout to 30 seconds for slow networks
    
    // Callbacks for WebSocket events
    var onObjectCollected: ((String, String, String) -> Void)? // (object_id, found_by, found_at)
    var onObjectUncollected: ((String) -> Void)? // (object_id)
    var onAllFindsReset: (() -> Void)?
    var onConnectionError: ((String) -> Void)? // (error_message)
    var onNPCCreated: (([String: Any]) -> Void)? // NPC data
    var onNPCUpdated: (([String: Any]) -> Void)? // NPC data
    var onNPCDeleted: ((String) -> Void)? // (npc_id)
    var onLocationUpdateIntervalChanged: ((Double) -> Void)? // (interval_seconds)
    var onGameModeChanged: ((String) -> Void)? // (game_mode)
    
    var baseURL: String {
        // Use the same validated baseURL as APIService to ensure consistency
        return APIService.shared.baseURL
    }
    
    private init() {
        // Start periodic health checks
        startHealthCheckTimer()
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Connection Management
    
    func connect() {
        guard !isConnected else {
            print("🔌 WebSocket already connected")
            return
        }
        
        // Don't connect if offline mode is enabled
        if OfflineModeManager.shared.isOfflineMode {
            print("📴 Offline mode enabled - skipping WebSocket connection")
            return
        }
        
        // Convert HTTP URL to WebSocket URL
        // Socket.IO endpoint: /socket.io/?EIO=4&transport=websocket
        let httpURL = baseURL.replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        
        let wsURLString = "\(httpURL)/socket.io/?EIO=4&transport=websocket"
        print("🔍 [WebSocket Connect] Base URL: \(baseURL)")
        print("🔍 [WebSocket Connect] HTTP URL: \(httpURL)")
        print("🔍 [WebSocket Connect] WebSocket URL: \(wsURLString)")
        
        guard let wsURL = URL(string: wsURLString) else {
            let errorMsg = "Invalid WebSocket URL: \(httpURL)"
            print("❌ [WebSocket Connect] Failed to create URL from: \(wsURLString)")
            print("   Base URL was: \(baseURL)")
            connectionStatus = .error(errorMsg)
            DispatchQueue.main.async {
                self.onConnectionError?(errorMsg)
            }
            return
        }
        
        connectionStatus = .connecting
        handshakeState = .waitingForSessionInfo
        
        // Start connection timeout timer
        startConnectionTimeoutTimer()
        
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: WebSocketDelegate(service: self), delegateQueue: nil)
        
        webSocketTask = urlSession?.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        
        receiveMessage()
        
        print("🔌 [WebSocket Connect] Attempting connection to \(wsURL)")
    }
    
    func disconnect() {
        stopPingTimer()
        stopReconnectTimer()
        stopConnectionTimeoutTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        connectionStatus = .disconnected
        handshakeState = .notStarted
        print("🔌 WebSocket disconnected")
    }
    
    // MARK: - Health Check
    
    private func startHealthCheckTimer() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.checkConnectionHealth()
        }
    }
    
    private func checkConnectionHealth() {
        // Check if API is available (this indicates server is running)
        Task {
            do {
                let isHealthy = try await APIService.shared.checkHealth()
                if isHealthy && !isConnected {
                    // Server is up but WebSocket not connected, try to connect
                    await MainActor.run {
                        if connectionStatus == .disconnected {
                            connect()
                        }
                    }
                } else if !isHealthy {
                    // Server is down
                    await MainActor.run {
                        isConnected = false
                        connectionStatus = .disconnected
                    }
                    // Notify that connection failed - trigger QR scanner
                    NotificationCenter.default.post(name: NSNotification.Name("APIConnectionFailed"), object: nil)
                }
            } catch {
                // Server unavailable
                await MainActor.run {
                    isConnected = false
                    connectionStatus = .disconnected
                }
                // Notify that connection failed - trigger QR scanner
                NotificationCenter.default.post(name: NSNotification.Name("APIConnectionFailed"), object: nil)
            }
        }
    }
    
    // MARK: - Message Handling
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("📨 WebSocket received: \(text)")
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        print("📨 WebSocket received (data): \(text)")
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving messages
                self.receiveMessage()
                
            case .failure(let error):
                print("❌ [WebSocket Receive] Error: \(error)")
                print("   Error type: \(type(of: error))")
                self.handleError(error)
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        print("📨 WebSocket received raw: \(text)")
        
        // Socket.IO handshake protocol:
        // 1. Server sends "0" packet with session info: 0{"sid":"...","upgrades":[],"pingInterval":25000,"pingTimeout":5000}
        // 2. Client sends "40" to connect to default namespace
        // 3. Server responds with "40" to confirm namespace connection
        
        // Handle Socket.IO handshake
        if text.hasPrefix("0{") {
            // Received session info packet - now send "40" to connect to namespace
            print("✅ Received Socket.IO session info, connecting to namespace...")
            handshakeState = .waitingForNamespaceConfirmation
            sendSocketIOPacket("40")
            return
        }
        
        // Handle namespace confirmation: "40" or "40{...}" (with optional session data)
        if text == "40" || text.hasPrefix("40{") {
            // Received namespace confirmation - handshake complete!
            // Extract session ID if present
            if text.hasPrefix("40{") {
                // Parse session data: 40{"sid":"..."}
                let jsonPart = String(text.dropFirst(2)) // Remove "40" prefix
                if let jsonData = jsonPart.data(using: .utf8),
                   let sessionData = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let sid = sessionData["sid"] as? String {
                    print("✅ Socket.IO handshake complete! Session ID: \(sid)")
                } else {
                    print("✅ Socket.IO handshake complete! (with session data)")
                }
            } else {
                print("✅ Socket.IO handshake complete!")
            }
            handshakeState = .completed
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionStatus = .connected
                self.stopConnectionTimeoutTimer()
                self.stopReconnectTimer()
                // Register device with server
                self.registerDevice()
                // Wait a moment before starting ping to ensure connection is fully established
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.startPingTimer()
                    print("📡 [Ping] Started ping timer (will ping every \(Int(self.pingInterval))s)")
                }
            }
            return
        }
        
        // Handle Socket.IO event messages: format is "42["event_name", {...}]"
        // Example: 42["object_collected",{"object_id":"abc","found_by":"user123","found_at":"2024-..."}]
        if text.hasPrefix("42[") {
            // Check if this is the 'connected' event from the server
            if text.contains("\"connected\"") || text.contains("'connected'") {
                // Server sent connected event - handshake is complete
                print("✅ Received Socket.IO 'connected' event from server")
                if handshakeState != .completed {
                    handshakeState = .completed
                    DispatchQueue.main.async {
                        self.isConnected = true
                        self.connectionStatus = .connected
                        self.stopConnectionTimeoutTimer()
                        self.stopReconnectTimer()
                        // Register device with server
                        self.registerDevice()
                        // Wait a moment before starting ping to ensure connection is fully established
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.startPingTimer()
                            print("📡 [Ping] Started ping timer (will ping every \(Int(self.pingInterval))s)")
                        }
                    }
                }
            }
            parseSocketIOEvent(text)
            return
        }
        
        // Handle other Socket.IO packet types
        if text == "2" {
            // Server sent ping - respond with pong "3"
            lastServerPingTime = Date()
            print("📥 [Ping] Received ping from server, sending pong")
            sendSocketIOPacket("3")
            // Reset failure count since we're receiving server pings
            pingPongFailures = 0
            return
        }
        
        if text == "3" {
            // Pong response (we sent ping "2", server responds with "3")
            lastPongTime = Date()
            if let pingTime = lastPingTime {
                let latency = lastPongTime!.timeIntervalSince(pingTime) * 1000 // Convert to ms
                print("📡 [Pong] Received Socket.IO pong response (latency: \(String(format: "%.0f", latency))ms)")
            } else {
                print("📡 [Pong] Received Socket.IO pong response")
            }
            pingPongFailures = 0 // Reset failure count on successful pong
            return
        }
        
        // Legacy check for backward compatibility (in case server sends different format)
        if text.contains("connected") && handshakeState == .waitingForNamespaceConfirmation {
            print("✅ Received connection confirmation (legacy format)")
            handshakeState = .completed
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionStatus = .connected
                self.stopConnectionTimeoutTimer()
                self.stopReconnectTimer()
                // Register device with server
                self.registerDevice()
                self.startPingTimer()
            }
            return
        }
        
        // Log unhandled messages for debugging, but don't treat as errors
        // Some Socket.IO servers send additional packets that we can safely ignore
        if text.count < 100 { // Only log short messages to avoid spam
            print("ℹ️ [Socket.IO] Unhandled message (may be normal): \(text.prefix(50))")
        }
    }
    
    /// Register device UUID with server
    private func registerDevice() {
        let deviceUUID = APIService.shared.currentUserID
        print("📱 [Device Registration] Registering device UUID: \(deviceUUID)")
        
        // Send register_device event: 42["register_device", {"device_uuid": "..."}]
        let registerEvent: [String: Any] = [
            "device_uuid": deviceUUID
        ]
        let jsonData: [Any] = ["register_device", registerEvent]
        
        if let json = try? JSONSerialization.data(withJSONObject: jsonData),
           let jsonString = String(data: json, encoding: .utf8) {
            let packet = "42\(jsonString)"
            sendSocketIOPacket(packet)
            print("📤 [Device Registration] Sent register_device event")
        } else {
            print("❌ [Device Registration] Failed to serialize register_device event")
        }
    }
    
    /// Send a Socket.IO packet
    private func sendSocketIOPacket(_ packet: String) {
        guard let webSocketTask = webSocketTask else {
            print("❌ Cannot send packet: WebSocket not connected")
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(packet)
        webSocketTask.send(message) { [weak self] error in
            if let error = error {
                print("❌ Failed to send Socket.IO packet '\(packet)': \(error)")
                self?.handleError(error)
            } else {
                // Only log non-ping packets to reduce noise (ping is every 30s)
                if packet != "2" {
                    print("📤 Sent Socket.IO packet: \(packet)")
                }
            }
        }
    }
    
    // Track ping/pong for diagnostics
    private var lastPingTime: Date? // When we sent a ping (not used anymore, but kept for compatibility)
    private var lastPongTime: Date? // When we received a pong (not used anymore, but kept for compatibility)
    private var lastServerPingTime: Date? // When we received a ping from server
    private var pingPongFailures: Int = 0
    
    /// Parse Socket.IO event message format: 42["event_name", {...}]
    private func parseSocketIOEvent(_ text: String) {
        // Find the opening bracket after "42["
        guard let startIndex = text.index(text.startIndex, offsetBy: 3, limitedBy: text.endIndex) else { return }
        
        // Extract the JSON array part: ["event_name", {...}]
        let jsonPart = String(text[startIndex...])
        
        // Try to parse as JSON array
        guard let jsonData = jsonPart.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              jsonArray.count >= 2,
              let eventName = jsonArray[0] as? String,
              let eventData = jsonArray[1] as? [String: Any] else {
            // Fallback: try simple string matching for common events
            if text.contains("object_collected") {
                print("⚠️ Received object_collected event but couldn't parse data")
            }
            return
        }
        
        // Handle different event types
        switch eventName {
        case "object_collected":
            handleObjectCollectedEvent(eventData)
            
        case "object_uncollected":
            handleObjectUncollectedEvent(eventData)
            
        case "all_finds_reset":
            handleAllFindsResetEvent()
            
        case "admin_diagnostic_ping":
            handleAdminDiagnosticPing(eventData)
            
        case "object_created":
            handleObjectCreatedEvent(eventData)
            
        case "object_deleted":
            handleObjectDeletedEvent(eventData)
            
        case "npc_created":
            handleNPCCreatedEvent(eventData)
            
        case "npc_updated":
            handleNPCUpdatedEvent(eventData)
            
        case "npc_deleted":
            handleNPCDeletedEvent(eventData)
            
        case "location_update_interval_changed":
            handleLocationUpdateIntervalChangedEvent(eventData)
            
        case "game_mode_changed":
            handleGameModeChangedEvent(eventData)
            
        default:
            print("📨 Received unhandled Socket.IO event: \(eventName)")
        }
    }
    
    /// Handle object_collected event: {"object_id": "...", "found_by": "...", "found_at": "..."}
    private func handleObjectCollectedEvent(_ data: [String: Any]) {
        guard let objectId = data["object_id"] as? String else {
            print("⚠️ object_collected event missing object_id")
            return
        }
        
        let foundBy = data["found_by"] as? String ?? "unknown"
        let foundAt = data["found_at"] as? String ?? ""
        
        print("🎯 WebSocket: Object collected - ID: \(objectId), by: \(foundBy)")
        
        DispatchQueue.main.async {
            self.onObjectCollected?(objectId, foundBy, foundAt)
        }
    }
    
    /// Handle object_uncollected event: {"object_id": "..."}
    private func handleObjectUncollectedEvent(_ data: [String: Any]) {
        guard let objectId = data["object_id"] as? String else {
            print("⚠️ object_uncollected event missing object_id")
            return
        }
        
        print("🔄 WebSocket: Object uncollected - ID: \(objectId)")
        
        DispatchQueue.main.async {
            self.onObjectUncollected?(objectId)
        }
    }
    
    /// Handle all_finds_reset event
    private func handleAllFindsResetEvent() {
        print("🔄 WebSocket: All finds reset")
        
        DispatchQueue.main.async {
            self.onAllFindsReset?()
        }
    }
    
    /// Handle object_created event: {"id": "...", "name": "...", ...}
    private func handleObjectCreatedEvent(_ data: [String: Any]) {
        print("📦 WebSocket: Object created - ID: \(data["id"] ?? "unknown")")
        
        DispatchQueue.main.async {
            // Pass the full object data to the handler
            NotificationCenter.default.post(
                name: NSNotification.Name("WebSocketObjectCreated"),
                object: nil,
                userInfo: data
            )
        }
    }
    
    /// Handle object_deleted event: {"object_id": "..."}
    private func handleObjectDeletedEvent(_ data: [String: Any]) {
        guard let objectId = data["object_id"] as? String else {
            print("⚠️ object_deleted event missing object_id")
            return
        }
        
        print("🗑️ WebSocket: Object deleted - ID: \(objectId)")
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("WebSocketObjectDeleted"),
                object: nil,
                userInfo: ["object_id": objectId]
            )
        }
    }
    
    /// Handle npc_created event: {"id": "...", "name": "...", ...}
    private func handleNPCCreatedEvent(_ data: [String: Any]) {
        guard let npcId = data["id"] as? String else {
            print("⚠️ npc_created event missing id")
            return
        }
        
        print("💬 WebSocket: NPC created - ID: \(npcId), Name: \(data["name"] ?? "unknown")")
        
        DispatchQueue.main.async {
            self.onNPCCreated?(data)
        }
    }
    
    /// Handle npc_updated event: {"id": "...", "name": "...", ...}
    private func handleNPCUpdatedEvent(_ data: [String: Any]) {
        guard let npcId = data["id"] as? String else {
            print("⚠️ npc_updated event missing id")
            return
        }
        
        print("💬 WebSocket: NPC updated - ID: \(npcId), Name: \(data["name"] ?? "unknown")")
        
        DispatchQueue.main.async {
            self.onNPCUpdated?(data)
        }
    }
    
    /// Handle npc_deleted event: {"npc_id": "..."}
    private func handleNPCDeletedEvent(_ data: [String: Any]) {
        guard let npcId = data["npc_id"] as? String else {
            print("⚠️ npc_deleted event missing npc_id")
            return
        }
        
        print("💬 WebSocket: NPC deleted - ID: \(npcId)")
        
        DispatchQueue.main.async {
            self.onNPCDeleted?(npcId)
        }
    }
    
    /// Handle location_update_interval_changed event: {"interval_ms": 1000, "interval_seconds": 1.0}
    private func handleLocationUpdateIntervalChangedEvent(_ data: [String: Any]) {
        guard let intervalSeconds = data["interval_seconds"] as? Double else {
            print("⚠️ location_update_interval_changed event missing interval_seconds")
            return
        }
        
        print("📍 WebSocket: Location update interval changed to \(intervalSeconds)s")
        
        DispatchQueue.main.async {
            self.onLocationUpdateIntervalChanged?(intervalSeconds)
        }
    }
    
    /// Handle game_mode_changed event: {"game_mode": "open"}
    private func handleGameModeChangedEvent(_ data: [String: Any]) {
        guard let gameMode = data["game_mode"] as? String else {
            print("⚠️ game_mode_changed event missing game_mode")
            return
        }
        
        print("🎮 WebSocket: Game mode changed to \(gameMode)")
        
        DispatchQueue.main.async {
            self.onGameModeChanged?(gameMode)
        }
    }
    
    /// Handle admin diagnostic ping event
    private func handleAdminDiagnosticPing(_ data: [String: Any]) {
        guard let pingId = data["ping_id"] as? String,
              let adminSessionId = data["admin_session_id"] as? String else {
            print("⚠️ admin_diagnostic_ping event missing required fields")
            return
        }
        
        print("📡 Received admin diagnostic ping (ping_id: \(pingId))")
        
        // Respond with pong
        let clientTimestamp = ISO8601DateFormatter().string(from: Date())
        let pongEvent = [
            "ping_id": pingId,
            "client_timestamp": clientTimestamp,
            "admin_session_id": adminSessionId
        ]
        
        // Send as Socket.IO event: 42["client_diagnostic_pong", {...}]
        let jsonData: [Any] = ["client_diagnostic_pong", pongEvent]
        if let json = try? JSONSerialization.data(withJSONObject: jsonData),
           let jsonString = String(data: json, encoding: .utf8) {
            let packet = "42\(jsonString)"
            sendSocketIOPacket(packet)
            print("📤 Sent client diagnostic pong (ping_id: \(pingId))")
        }
    }
    
    func sendPing() {
        guard isConnected, handshakeState == .completed else {
            print("⚠️ [Ping] Skipping ping - not fully connected (isConnected: \(isConnected), handshakeState: \(handshakeState))")
            return
        }
        // Socket.IO ping is packet type "2"
        lastPingTime = Date()
        print("📤 [Ping] Sending Socket.IO ping packet (attempt \(pingPongFailures + 1))")
        sendSocketIOPacket("2")
        
        // Check if we received pong within 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            if let pingTime = self.lastPingTime, self.lastPongTime == nil || self.lastPongTime! < pingTime {
                self.pingPongFailures += 1
                print("⚠️ [Ping/Pong] No pong received after ping (failures: \(self.pingPongFailures))")
                if self.pingPongFailures >= 3 {
                    print("❌ [Ping/Pong] Multiple ping/pong failures detected")
                    print("   This may indicate:")
                    print("   • Server not responding to Socket.IO protocol ping/pong")
                    print("   • Connection not fully established despite handshake")
                    print("   • Network issues or firewall blocking")
                    print("   • Flask-SocketIO version compatibility issue")
                    // Don't disconnect automatically - connection might still work for events
                    // But log the issue for debugging
                }
            } else {
                // Reset failure count on success
                if self.pingPongFailures > 0 {
                    print("✅ [Ping/Pong] Pong received - connection is healthy again")
                }
                self.pingPongFailures = 0
            }
        }
    }
    
    // MARK: - Timers
    
    private func startPingTimer() {
        stopPingTimer()
        // Note: We don't send client-initiated pings anymore
        // Flask-SocketIO server sends pings, and we respond with pongs
        // This avoids ping/pong failures in threading mode
        // The server is configured to ping every 25 seconds, and we respond automatically
        // Monitor if we stop receiving server pings (indicates connection issue)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let lastPing = self.lastServerPingTime {
                let timeSinceLastPing = Date().timeIntervalSince(lastPing)
                if timeSinceLastPing > 60.0 {
                    // Haven't received server ping in over 60 seconds
                    self.pingPongFailures += 1
                    print("⚠️ [Ping/Pong] Haven't received server ping in \(Int(timeSinceLastPing))s (failures: \(self.pingPongFailures))")
                    if self.pingPongFailures >= 3 {
                        print("❌ [Ping/Pong] Server ping timeout - connection may be stale")
                    }
                } else {
                    // Reset failures if we're receiving pings regularly
                    if self.pingPongFailures > 0 {
                        print("✅ [Ping/Pong] Receiving server pings regularly again")
                        self.pingPongFailures = 0
                    }
                }
            } else {
                // No server ping received yet - give it time
                print("ℹ️ [Ping/Pong] Waiting for first server ping...")
            }
        }
        print("📡 [Ping] Ping monitor started - will track server pings (server pings every 25s)")
    }
    
    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
    
    private func startReconnectTimer() {
        stopReconnectTimer()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
    
    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    // MARK: - Connection Handlers
    
    func handleConnection() {
        // WebSocket is open, but Socket.IO handshake hasn't completed yet
        // We'll wait for the "0" session info packet before proceeding
        print("✅ WebSocket opened, waiting for Socket.IO handshake...")
        // Don't set isConnected = true yet - wait for Socket.IO handshake to complete
    }
    
    func handleDisconnection() {
        let wasConnected = isConnected
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .disconnected
            self.handshakeState = .notStarted
        }
        print("⚠️ WebSocket disconnected")
        
        // Attempt to reconnect if we were previously connected
        if wasConnected {
            startReconnectTimer()
        }
    }
    
    func handleError(_ error: Error) {
        stopConnectionTimeoutTimer()
        
        // Build WebSocket URL for logging
        let httpURL = baseURL.replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        let wsURLString = "\(httpURL)/socket.io/?EIO=4&transport=websocket"
        
        // Enhanced error logging for root cause analysis
        var errorMsg = error.localizedDescription
        
        // Log detailed error information
        if let urlError = error as? URLError {
            let errorCode = urlError.code
            print("❌ WebSocket error: \(errorMsg)")
            print("   Error type: \(type(of: error))")
            print("   URLError code: \(urlError.code.rawValue) (\(errorCode))")
            print("   Failed URL (from error): \(urlError.failureURLString ?? "unknown")")
            
            // Provide more helpful error messages based on error code
            switch errorCode {
            case .cannotConnectToHost:
                // Test HTTP connectivity first to provide better diagnostics
                Task {
                    await testHTTPConnectivity()
                }
                
                // Build detailed troubleshooting message
                var troubleshooting = "Cannot connect to server at \(baseURL).\n\nThis usually means:\n• Server is not running (check: python app.py in server/ directory)\n• Wrong IP address (current: \(baseURL))"
                
                // Check if IP looks like a router/gateway (ends in .1)
                if baseURL.contains(".1:") || baseURL.contains(".1/") {
                    troubleshooting += "\n\n⚠️ WARNING: IP ends in .1 - this is usually the ROUTER, not your computer!"
                    
                    // Auto-detect device IP and suggest it
                    if let deviceIP = NetworkHelper.getDeviceIP() {
                        let suggestedURL = "http://\(deviceIP):5001"
                        troubleshooting += "\n\n   💡 Your computer's IP appears to be: \(deviceIP)"
                        troubleshooting += "\n   💡 Try updating Settings → API Server URL to: \(suggestedURL)"
                        
                        // Store suggested URL for potential auto-correction
                        print("💡 Auto-detected device IP: \(deviceIP)")
                        print("💡 Suggested URL: \(suggestedURL)")
                    } else {
                        troubleshooting += "\n   💡 Your computer's IP is likely 192.168.68.XX (NOT .1)"
                    }
                    
                    troubleshooting += "\n\n   To fix:"
                    troubleshooting += "\n   1. Open Settings → API Server URL"
                    if let deviceIP = NetworkHelper.getDeviceIP() {
                        troubleshooting += "\n   2. Change to: http://\(deviceIP):5001"
                    } else {
                        troubleshooting += "\n   2. Change to your computer's actual IP (see below)"
                    }
                    troubleshooting += "\n   3. Tap 'Save URL'"
                    troubleshooting += "\n\n   Or use 'Test Multiple Ports' in Settings to auto-discover the server!"
                }
                
                troubleshooting += "\n• Device and server are on different Wi-Fi networks\n• Firewall is blocking port 5001\n\nTroubleshooting:\n1. Verify server IP: Check your computer's IP with 'ifconfig' (Mac) or 'ipconfig' (Windows)\n2. Test in browser: Open \(baseURL)/health\n3. Check Wi-Fi: Ensure device and server are on the same network\n4. Check firewall: macOS may block incoming connections (System Settings → Network → Firewall)\n5. Try 'Test Multiple Ports' in Settings to find the correct server"
                
                errorMsg = troubleshooting
            case .timedOut:
                errorMsg = "Connection timed out to \(baseURL).\n\nPossible causes:\n• Server is slow to respond\n• Network congestion\n• Firewall blocking connection\n• Server not running"
            case .networkConnectionLost:
                errorMsg = "Network connection lost. Check your Wi-Fi connection."
            case .notConnectedToInternet:
                // Error -1009 often means can't reach local network server, not necessarily no internet
                var troubleshooting = "Cannot reach server at \(baseURL).\n\nThis usually means:\n• Server is not running (check: python app.py in server/ directory)\n• Wrong IP address (current: \(baseURL))"
                
                // Check if IP looks like a router/gateway (ends in .1)
                if baseURL.contains(".1:") || baseURL.contains(".1/") {
                    troubleshooting += "\n\n⚠️ WARNING: IP ends in .1 - this is usually the ROUTER, not your computer!"
                    
                    // Auto-detect device IP and suggest it
                    if let deviceIP = NetworkHelper.getDeviceIP() {
                        let suggestedURL = "http://\(deviceIP):5001"
                        troubleshooting += "\n\n   💡 Your computer's IP appears to be: \(deviceIP)"
                        troubleshooting += "\n   💡 Try updating Settings → API Server URL to: \(suggestedURL)"
                        
                        print("💡 Auto-detected device IP: \(deviceIP)")
                        print("💡 Suggested URL: \(suggestedURL)")
                    } else {
                        troubleshooting += "\n   💡 Your computer's IP is likely 192.168.68.XX (NOT .1)"
                    }
                    
                    troubleshooting += "\n\n   To fix:"
                    troubleshooting += "\n   1. Open Settings → API Server URL"
                    if let deviceIP = NetworkHelper.getDeviceIP() {
                        troubleshooting += "\n   2. Change to: http://\(deviceIP):5001"
                    } else {
                        troubleshooting += "\n   2. Change to your computer's actual IP"
                    }
                    troubleshooting += "\n   3. Tap 'Save URL'"
                    troubleshooting += "\n\n   Or use 'Test Multiple Ports' to auto-discover!"
                }
                
                troubleshooting += "\n• Device and server are on different Wi-Fi networks\n• Firewall is blocking port 5001\n\nTroubleshooting:\n1. Verify server IP: Check your computer's IP with 'ifconfig' (Mac) or 'ipconfig' (Windows)\n2. Test in browser: Open \(baseURL)/health\n3. Check Wi-Fi: Ensure device and server are on the same network\n4. Try 'Test Multiple Ports' in Settings to find the correct server"
                
                errorMsg = troubleshooting
            default:
                break
            }
            
            let nsError = error as NSError
            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                print("   Underlying error: \(underlyingError)")
            }
        } else if let nsError = error as NSError? {
            print("❌ WebSocket error: \(errorMsg)")
            print("   Error type: \(type(of: error))")
            print("   NSError domain: \(nsError.domain)")
            print("   NSError code: \(nsError.code)")
            print("   User info: \(nsError.userInfo)")
        } else {
            print("❌ WebSocket error: \(errorMsg)")
            print("   Error type: \(type(of: error))")
        }
        
        print("   Base URL: \(baseURL)")
        print("   WebSocket URL (attempted): \(wsURLString)")
        print("   Handshake state: \(handshakeState)")
        print("   Connection status: \(connectionStatus)")
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .error(errorMsg)
            self.handshakeState = .notStarted
            self.onConnectionError?(errorMsg)
        }
        
        // Attempt to reconnect
        startReconnectTimer()
    }
    
    /// Test HTTP connectivity to help diagnose connection issues
    private func testHTTPConnectivity() async {
        print("🔍 [Diagnostics] Testing HTTP connectivity to \(baseURL)")
        
        // Test health endpoint first
        do {
            let isHealthy = try await APIService.shared.checkHealth()
            if isHealthy {
                print("✅ [Diagnostics] HTTP connection works! Server is reachable via HTTP.")
                print("   ⚠️ WebSocket connection failed even though HTTP works.")
                print("   This suggests:")
                print("   • Server may not support WebSocket/Socket.IO")
                print("   • WebSocket endpoint may be misconfigured")
                print("   • Firewall may be blocking WebSocket upgrade")
                print("   • Server might need Socket.IO client library configuration")
            } else {
                print("❌ [Diagnostics] HTTP health check failed - server may not be running")
            }
        } catch {
            print("❌ [Diagnostics] HTTP connection test failed: \(error.localizedDescription)")
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cannotConnectToHost:
                    print("   → Server is not reachable at \(baseURL)")
                    print("   → Troubleshooting steps:")
                    print("     1. Check if server is running: python app.py (in server/ directory)")
                    print("     2. Verify IP address: Should match your computer's local IP")
                    print("     3. Check network: Device and server must be on same Wi-Fi")
                    print("     4. Test in browser: Open \(baseURL)/health")
                    print("     5. Check firewall: macOS may block incoming connections")
                case .timedOut:
                    print("   → Connection timed out - server may be slow or firewall blocking")
                default:
                    print("   → Error code: \(urlError.code)")
                }
            }
        }
    }
    
    /// Comprehensive connection diagnostic
    func runDiagnostics(completion: @escaping (String) -> Void) {
        var diagnostics: [String] = []
        diagnostics.append("🔍 Connection Diagnostics for \(baseURL)\n")
        
        // Test 1: HTTP connectivity
        Task {
            diagnostics.append("Test 1: HTTP Health Check...")
            do {
                let isHealthy = try await APIService.shared.checkHealth()
                if isHealthy {
                    diagnostics.append("✅ HTTP connection works!")
                } else {
                    diagnostics.append("❌ HTTP health check failed")
                }
            } catch {
                diagnostics.append("❌ HTTP test failed: \(error.localizedDescription)")
            }
            
            // Test 2: WebSocket connectivity
            diagnostics.append("\nTest 2: WebSocket Connection...")
            testConnection { result in
                if result.connected {
                    diagnostics.append("✅ WebSocket connection works!")
                } else {
                    diagnostics.append("❌ WebSocket failed: \(result.error ?? "Unknown error")")
                }
                
                // Test 3: Multiple ports
                diagnostics.append("\nTest 3: Testing Multiple Ports...")
                let baseURL = APIService.shared.baseURL
                let host: String
                if let url = URL(string: baseURL), let hostComponent = url.host {
                    host = hostComponent
                } else {
                    let components = baseURL.replacingOccurrences(of: "http://", with: "")
                        .replacingOccurrences(of: "https://", with: "")
                        .split(separator: ":")
                    host = String(components.first ?? "localhost")
                }
                
                self.testMultiplePorts(baseHost: host) { multiResult in
                    if let workingPort = multiResult.workingPort {
                        diagnostics.append("✅ Found working port: \(workingPort)")
                        diagnostics.append("   Working URL: \(multiResult.workingURL ?? "unknown")")
                    } else {
                        diagnostics.append("❌ No working ports found")
                        diagnostics.append("   Failed ports: \(multiResult.failedPorts.map { "\($0.port)" }.joined(separator: ", "))")
                    }
                    
                    let report = diagnostics.joined(separator: "\n")
                    completion(report)
                }
            }
        }
    }
    
    // MARK: - Connection Timeout
    
    private func startConnectionTimeoutTimer() {
        stopConnectionTimeoutTimer()
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeoutInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Check if we're still in connecting state and handshake hasn't completed
            let currentHandshakeState = self.handshakeState
            let isHandshakeCompleted: Bool = {
                switch currentHandshakeState {
                case .completed:
                    return true
                default:
                    return false
                }
            }()
            if case .connecting = self.connectionStatus, !self.isConnected, !isHandshakeCompleted {
                let errorMsg = "Connection timeout: Unable to complete Socket.IO handshake to \(self.baseURL) after \(Int(self.connectionTimeoutInterval)) seconds. Please check:\n• Server is running\n• URL is correct\n• Device is on the same network\n• Firewall allows connections"
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.connectionStatus = .error(errorMsg)
                    self.handshakeState = .notStarted
                    self.onConnectionError?(errorMsg)
                }
                print("⏱️ WebSocket connection timeout (handshake state: \(self.handshakeState))")
                // Cancel the connection attempt
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession = nil
            }
        }
    }
    
    private func stopConnectionTimeoutTimer() {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
    }
    
    // MARK: - Connection Test
    
    /// Test WebSocket connection and return results
    func testConnection(completion: @escaping (TestResult) -> Void) {
        // Use a class wrapper to allow mutation in closures
        class TestResultWrapper {
            var result = TestResult()
        }
        let resultWrapper = TestResultWrapper()
        
        // Check if already connected
        let currentHandshakeState = handshakeState
        if isConnected && currentHandshakeState == .completed {
            resultWrapper.result.connected = true
            resultWrapper.result.connectionTime = 0
            resultWrapper.result.eventsReceived.append("connected")
            resultWrapper.result.pingReceived = true // Assume working if connected
            completion(resultWrapper.result)
            return
        }
        
        // Create a temporary test connection (separate from main connection)
        let startTime = Date()
        let httpURL = baseURL.replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        
        let wsURLString = "\(httpURL)/socket.io/?EIO=4&transport=websocket"
        print("🔍 [WebSocket Test] Base URL: \(baseURL)")
        print("🔍 [WebSocket Test] WebSocket URL: \(wsURLString)")
        
        guard let wsURL = URL(string: wsURLString) else {
            let errorMsg = "Invalid WebSocket URL: \(httpURL)"
            print("❌ [WebSocket Test] Failed to create URL: \(errorMsg)")
            resultWrapper.result.error = errorMsg
            completion(resultWrapper.result)
            return
        }
        
        // Create a minimal test session without delegate to avoid interference
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        let testSession = URLSession(configuration: config)
        let testTask = testSession.webSocketTask(with: wsURL)
        
        print("🔍 [WebSocket Test] Starting test connection to \(wsURL)")

        var pingReceived = false
        var connectedReceived = false
        var testCompleted = false
        
        // Set up message receiver
        func receiveTestMessage() {
            guard !testCompleted else { return }
            testTask.receive { result in
                guard !testCompleted else { return }
                switch result {
                case .success(let message):
                    let text: String
                    switch message {
                    case .string(let str):
                        text = str
                    case .data(let data):
                        text = String(data: data, encoding: .utf8) ?? ""
                    @unknown default:
                        text = ""
                    }
                    
                    // Handle Socket.IO handshake
                    if text.hasPrefix("0{") {
                        let message = URLSessionWebSocketTask.Message.string("40")
                        testTask.send(message) { _ in }
                        receiveTestMessage()
                        return
                    }
                    
                    if text == "40" {
                        resultWrapper.result.connected = true
                        resultWrapper.result.connectionTime = Date().timeIntervalSince(startTime)
                        connectedReceived = true
                        
                        // Send ping
                        let pingMessage = URLSessionWebSocketTask.Message.string("2")
                        testTask.send(pingMessage) { _ in }
                        receiveTestMessage()
                        return
                    }
                    
                    if text == "3" {
                        pingReceived = true
                        resultWrapper.result.pingReceived = true
                    }
                    
                    if text.hasPrefix("42[") && (text.contains("\"connected\"") || text.contains("'connected'")) {
                        if !connectedReceived {
                            resultWrapper.result.connected = true
                            resultWrapper.result.connectionTime = Date().timeIntervalSince(startTime)
                            resultWrapper.result.eventsReceived.append("connected")
                        }
                    }
                    
                    // Continue receiving
                    receiveTestMessage()
                    
                case .failure(let error):
                    // Connection failed or closed
                    print("❌ [WebSocket Test] Connection failed: \(error.localizedDescription)")
                    print("   Error type: \(type(of: error))")
                    
                    if let urlError = error as? URLError {
                        print("   URLError code: \(urlError.code.rawValue) (\(urlError.code))")
                        print("   Failed URL: \(urlError.failureURLString ?? "unknown")")
                        let nsError = error as NSError
                        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                            print("   Underlying error: \(underlyingError)")
                        }
                        resultWrapper.result.error = "URLError: \(urlError.code) - \(urlError.localizedDescription)"
                    } else if let nsError = error as NSError? {
                        print("   NSError domain: \(nsError.domain)")
                        print("   NSError code: \(nsError.code)")
                        resultWrapper.result.error = "NSError [\(nsError.domain):\(nsError.code)]: \(error.localizedDescription)"
                    } else {
                        resultWrapper.result.error = error.localizedDescription
                    }
                    
                    if !resultWrapper.result.connected && resultWrapper.result.error == nil {
                        resultWrapper.result.error = "Connection failed: \(error.localizedDescription)"
                    }
                    testCompleted = true
                    testTask.cancel(with: .goingAway, reason: nil)
                    
                    // Finalize results
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if resultWrapper.result.connected {
                            resultWrapper.result.pingReceived = pingReceived
                        }
                        completion(resultWrapper.result)
                    }
                }
            }
        }
        
        // Start connection
        testTask.resume()
        receiveTestMessage()
        
        // Timeout after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard !testCompleted else { return }
            testCompleted = true
            print("⏱️ [WebSocket Test] Connection test timed out after 5 seconds")
            print("   Connected: \(resultWrapper.result.connected)")
            print("   Ping received: \(pingReceived)")
            testTask.cancel(with: .goingAway, reason: nil)
            if !resultWrapper.result.connected {
                resultWrapper.result.error = "Connection timeout after 5 seconds. Check:\n• Server is running at \(self.baseURL)\n• Device is on the same network\n• Firewall allows connections\n• URL is correct"
            } else {
                resultWrapper.result.pingReceived = pingReceived
            }
            completion(resultWrapper.result)
        }
    }
    
    struct TestResult {
        var connected: Bool = false
        var pingReceived: Bool = false
        var connectionTime: TimeInterval = 0
        var eventsReceived: [String] = []
        var error: String?
        var testedURL: String?
        var port: Int?
        
        var summary: String {
            var parts: [String] = []
            parts.append("Connection: \(connected ? "✅" : "❌")")
            if connected {
                parts.append("Ping/Pong: \(pingReceived ? "✅" : "❌")")
                parts.append("Connection Time: \(String(format: "%.2f", connectionTime))s")
                parts.append("Events: \(eventsReceived.count)")
                if let url = testedURL {
                    parts.append("URL: \(url)")
                }
            }
            if let error = error {
                parts.append("Error: \(error)")
            }
            return parts.joined(separator: "\n")
        }
    }
    
    // MARK: - Multi-Port Connection Test
    
    /// Test connection on multiple ports and return the first successful one
    func testMultiplePorts(
        baseHost: String,
        ports: [Int] = [5001, 5000, 8080, 3000, 8000, 5002],
        completion: @escaping (MultiPortTestResult) -> Void
    ) {
        // Use a class wrapper to allow mutation in closures
        class ResultWrapper {
            var result = MultiPortTestResult()
        }
        let resultWrapper = ResultWrapper()
        let testGroup = DispatchGroup()
        
        print("🔍 [Multi-Port Test] Testing \(ports.count) ports: \(ports.map { String($0) }.joined(separator: ", "))")
        
        for port in ports {
            testGroup.enter()
            let testURL = "http://\(baseHost):\(port)"
            
            // Create a temporary WebSocketService-like test
            let httpURL = testURL.replacingOccurrences(of: "http://", with: "ws://")
                .replacingOccurrences(of: "https://", with: "wss://")
            let wsURLString = "\(httpURL)/socket.io/?EIO=4&transport=websocket"
            
            guard let wsURL = URL(string: wsURLString) else {
                resultWrapper.result.failedPorts.append((port: port, error: "Invalid URL"))
                testGroup.leave()
                continue
            }
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3.0
            let testSession = URLSession(configuration: config)
            let testTask = testSession.webSocketTask(with: wsURL)
            
            var testCompleted = false
            var connected = false
            
            // Set up message receiver - capture resultWrapper explicitly
            func receiveTestMessage() {
                guard !testCompleted else { return }
                testTask.receive { receiveResult in
                    guard !testCompleted else { return }
                    switch receiveResult {
                    case .success(let message):
                        let text: String
                        switch message {
                        case .string(let str):
                            text = str
                        case .data(let data):
                            text = String(data: data, encoding: .utf8) ?? ""
                        @unknown default:
                            text = ""
                        }
                        
                        // Handle Socket.IO handshake
                        if text.hasPrefix("0{") {
                            let message = URLSessionWebSocketTask.Message.string("40")
                            testTask.send(message) { _ in }
                            receiveTestMessage()
                            return
                        }
                        
                        if text == "40" || text.hasPrefix("42[") {
                            if !connected {
                                connected = true
                                testCompleted = true
                                resultWrapper.result.workingPort = port
                                resultWrapper.result.workingURL = testURL
                                resultWrapper.result.workingWebSocketURL = wsURLString
                                print("✅ [Multi-Port Test] Port \(port) is working! URL: \(testURL)")
                                testTask.cancel(with: .goingAway, reason: nil)
                                testGroup.leave()
                            }
                            return
                        }
                        
                        receiveTestMessage()
                        
                    case .failure(let error):
                        if !testCompleted {
                            testCompleted = true
                            let errorMsg = error.localizedDescription
                            resultWrapper.result.failedPorts.append((port: port, error: errorMsg))
                            print("❌ [Multi-Port Test] Port \(port) failed: \(errorMsg)")
                            testTask.cancel(with: .goingAway, reason: nil)
                            testGroup.leave()
                        }
                    }
                }
            }
            
            // Start connection
            testTask.resume()
            receiveTestMessage()
            
            // Timeout after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if !testCompleted {
                    testCompleted = true
                    resultWrapper.result.failedPorts.append((port: port, error: "Timeout"))
                    print("⏱️ [Multi-Port Test] Port \(port) timed out")
                    testTask.cancel(with: .goingAway, reason: nil)
                    testGroup.leave()
                }
            }
        }
        
        // Wait for all tests to complete or find a working port
        testGroup.notify(queue: .main) {
            if resultWrapper.result.workingPort != nil {
                print("✅ [Multi-Port Test] Found working port: \(resultWrapper.result.workingPort!)")
            } else {
                print("❌ [Multi-Port Test] No working ports found")
                resultWrapper.result.error = "Could not connect to any port. Tried: \(ports.map { String($0) }.joined(separator: ", "))"
            }
            completion(resultWrapper.result)
        }
    }
    
    struct MultiPortTestResult {
        var workingPort: Int?
        var workingURL: String?
        var workingWebSocketURL: String?
        var failedPorts: [(port: Int, error: String)] = []
        var error: String?
        
        var summary: String {
            var parts: [String] = []
            if let port = workingPort, let url = workingURL {
                parts.append("✅ Working Port: \(port)")
                parts.append("✅ Working URL: \(url)")
            } else {
                parts.append("❌ No working port found")
            }
            if !failedPorts.isEmpty {
                parts.append("\nFailed ports:")
                for (port, error) in failedPorts {
                    parts.append("  Port \(port): \(error)")
                }
            }
            if let error = error {
                parts.append("\nError: \(error)")
            }
            return parts.joined(separator: "\n")
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    weak var service: WebSocketService?
    
    init(service: WebSocketService) {
        self.service = service
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        service?.handleConnection()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown reason"
        let closeCodeString = closeCodeDescription(closeCode)
        print("🔌 WebSocket closed: \(closeCodeString), reason: \(reasonString)")
        service?.handleDisconnection()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            service?.handleError(error)
        }
    }
    
    private func closeCodeDescription(_ code: URLSessionWebSocketTask.CloseCode) -> String {
        switch code {
        case .invalid:
            return "Invalid"
        case .normalClosure:
            return "Normal closure"
        case .goingAway:
            return "Going away"
        case .protocolError:
            return "Protocol error"
        case .unsupportedData:
            return "Unsupported data"
        case .noStatusReceived:
            return "No status received"
        case .abnormalClosure:
            return "Abnormal closure"
        case .invalidFramePayloadData:
            return "Invalid frame payload data"
        case .policyViolation:
            return "Policy violation"
        case .messageTooBig:
            return "Message too big"
        case .mandatoryExtensionMissing:
            return "Mandatory extension missing"
        case .internalServerError:
            return "Internal server error"
        case .tlsHandshakeFailure:
            return "TLS handshake failure"
        @unknown default:
            return "Unknown code (\(code.rawValue))"
        }
    }
}

