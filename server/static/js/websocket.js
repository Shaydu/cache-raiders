/**
 * WebSocket Manager - Handles WebSocket connection and real-time updates
 */
const WebSocketManager = {
    socket: null,
    connectedPlayers: new Set(),
    playerLastSeen: {},

    /**
     * Connect to WebSocket for real-time updates
     */
    connect() {
        try {
            this.socket = io(Config.API_BASE, {
                transports: ['websocket', 'polling']
            });

            this.socket.on('connect', () => {
                console.log('✅ Connected to WebSocket for real-time updates');
            });

            this.socket.on('disconnect', () => {
                console.log('❌ Disconnected from WebSocket');
            });

            this.socket.on('connect_error', (error) => {
                console.warn('⚠️ WebSocket connection error:', error);
            });

            // Listen for real-time user location updates
            this.socket.on('user_location_updated', (data) => {
                console.log('📨 Received user_location_updated event:', data);
                console.log(`   Device UUID: ${data.device_uuid?.substring(0, 8)}..., Location: (${data.latitude?.toFixed(6)}, ${data.longitude?.toFixed(6)})`);

                const deviceUuid = data.device_uuid;
                if (deviceUuid) {
                    this.connectedPlayers.add(deviceUuid);
                    this.playerLastSeen[deviceUuid] = Date.now();
                }

                UserLocationsManager.updateUserLocationMarker(data);

                // Refresh player list to update connection indicators
                PlayersManager.refreshPlayerListConnectionStatus();
            });
        } catch (error) {
            console.warn('⚠️ Failed to initialize WebSocket:', error);
        }
    },

    /**
     * Check if a player is currently connected (within last 60 seconds)
     */
    isPlayerConnected(deviceUuid) {
        if (this.connectedPlayers.has(deviceUuid)) {
            const lastSeen = this.playerLastSeen[deviceUuid];
            if (lastSeen) {
                const secondsSinceLastSeen = (Date.now() - lastSeen) / 1000;
                return secondsSinceLastSeen < (Config.DISCONNECTED_THRESHOLD / 1000);
            }
            return true; // If in set but no timestamp, assume connected
        }
        return false;
    },

    /**
     * Mark player as connected
     */
    markPlayerConnected(deviceUuid) {
        this.connectedPlayers.add(deviceUuid);
        this.playerLastSeen[deviceUuid] = Date.now();
    },

    /**
     * Periodically check for disconnected players
     */
    startConnectionMonitor() {
        setInterval(() => {
            const now = Date.now();
            const disconnected = [];

            this.connectedPlayers.forEach(deviceUuid => {
                const lastSeen = this.playerLastSeen[deviceUuid];
                if (lastSeen) {
                    const secondsSinceLastSeen = (now - lastSeen) / 1000;
                    if (secondsSinceLastSeen >= (Config.DISCONNECTED_THRESHOLD / 1000)) {
                        disconnected.push(deviceUuid);
                    }
                }
            });

            // Remove disconnected players from set
            disconnected.forEach(deviceUuid => {
                this.connectedPlayers.delete(deviceUuid);
            });

            // Refresh UI if any players were marked as disconnected
            if (disconnected.length > 0) {
                PlayersManager.refreshPlayerListConnectionStatus();
            }
        }, Config.CONNECTION_CHECK_INTERVAL);
    }
};

// Make WebSocketManager available globally
window.WebSocketManager = WebSocketManager;



