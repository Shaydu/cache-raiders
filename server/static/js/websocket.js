/**
 * WebSocket Manager - Handles WebSocket connection and real-time updates
 */
const WebSocketManager = {
    socket: null,
    connectedPlayers: new Set(),
    playerLastSeen: {},
    connectedClientsInterval: null,

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
                
                // Request connected clients list immediately upon connection
                this.socket.emit('get_connected_clients');
                
                // Set up periodic requests for connected clients list (every 10 seconds)
                // This ensures we detect new connections even if registration events are missed
                if (this.connectedClientsInterval) {
                    clearInterval(this.connectedClientsInterval);
                }
                this.connectedClientsInterval = setInterval(() => {
                    if (this.socket && this.socket.connected) {
                        this.socket.emit('get_connected_clients');
                    }
                }, 10000); // Request every 10 seconds
            });

            this.socket.on('disconnect', () => {
                console.log('❌ Disconnected from WebSocket');
                
                // Clear the interval when disconnected
                if (this.connectedClientsInterval) {
                    clearInterval(this.connectedClientsInterval);
                    this.connectedClientsInterval = null;
                }
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

            // Listen for connected clients list from server (for accurate connection status)
            this.socket.on('connected_clients_list', (data) => {
                console.log('📡 Received connected clients list from server:', data.clients);
                
                // Sync server's connected clients with our local tracking
                const serverConnectedUuids = new Set(
                    data.clients.map(client => client.device_uuid)
                );
                
                // Add all server-connected clients to our tracking
                serverConnectedUuids.forEach(deviceUuid => {
                    this.connectedPlayers.add(deviceUuid);
                    // Update last seen if not already set (or if it's been a while)
                    if (!this.playerLastSeen[deviceUuid] || 
                        (Date.now() - this.playerLastSeen[deviceUuid]) > 60000) {
                        this.playerLastSeen[deviceUuid] = Date.now();
                    }
                });
                
                // Remove clients that are no longer connected (but keep those that sent location updates recently)
                const now = Date.now();
                const disconnectedThreshold = Config.DISCONNECTED_THRESHOLD || 60000;
                
                this.connectedPlayers.forEach(deviceUuid => {
                    if (!serverConnectedUuids.has(deviceUuid)) {
                        // Only remove if we haven't seen a location update recently
                        const lastSeen = this.playerLastSeen[deviceUuid];
                        if (!lastSeen || (now - lastSeen) > disconnectedThreshold) {
                            this.connectedPlayers.delete(deviceUuid);
                            delete this.playerLastSeen[deviceUuid];
                        }
                    }
                });
                
                // Refresh player list to update connection indicators
                PlayersManager.refreshPlayerListConnectionStatus();
            });

            // Listen for object deleted events
            this.socket.on('object_deleted', (data) => {
                console.log('🗑️ Received object_deleted event:', data.object_id);
                if (ObjectsManager && typeof ObjectsManager.removeObjectMarker === 'function') {
                    ObjectsManager.removeObjectMarker(data.object_id);
                }
            });
        } catch (error) {
            console.warn('⚠️ Failed to initialize WebSocket:', error);
        }
    },

    /**
     * Check if a player is currently connected (within last 60 seconds)
     * Considers both WebSocket connections AND recent location updates
     */
    isPlayerConnected(deviceUuid) {
        // Check WebSocket connection
        if (this.connectedPlayers.has(deviceUuid)) {
            const lastSeen = this.playerLastSeen[deviceUuid];
            if (lastSeen) {
                const secondsSinceLastSeen = (Date.now() - lastSeen) / 1000;
                if (secondsSinceLastSeen < (Config.DISCONNECTED_THRESHOLD / 1000)) {
                    return true;
                }
            } else {
                return true; // If in set but no timestamp, assume connected
            }
        }
        
        // Also check if player has sent location updates recently (via HTTP or WebSocket)
        // This handles players who send location updates but aren't WebSocket connected
        if (UserLocationsManager && UserLocationsManager.userLocationMarkers) {
            const hasActiveMarker = UserLocationsManager.userLocationMarkers[deviceUuid] !== undefined;
            if (hasActiveMarker) {
                // Player has an active location marker, consider them connected
                // (markers are removed when location updates stop for 5+ minutes)
                return true;
            }
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
    },

    /**
     * Test WebSocket connection
     */
    async testConnection() {
        const testBtn = document.getElementById('wsTestBtn');
        const testResult = document.getElementById('wsTestResult');
        
        if (!testBtn || !testResult) {
            console.error('Test button or result element not found');
            return;
        }

        // Disable button and show testing state
        testBtn.disabled = true;
        testBtn.textContent = '🔄 Testing...';
        testResult.style.display = 'block';
        testResult.style.background = '#2a2a2a';
        testResult.style.color = '#ccc';
        testResult.style.border = '1px solid #444';
        testResult.innerHTML = '<div>🔌 Connecting to WebSocket server...</div>';

        const testSocket = io(Config.API_BASE, {
            transports: ['websocket', 'polling']
        });

        const testResults = {
            connected: false,
            pingReceived: false,
            eventsReceived: []
        };

        let testTimeout;

        // Set up event handlers
        testSocket.on('connect', () => {
            testResults.connected = true;
            testResult.innerHTML += '<div style="color: #4caf50; margin-top: 8px;">✅ Connected to WebSocket server</div>';
            
            // Test ping/pong
            testResult.innerHTML += '<div style="margin-top: 8px;">🏓 Testing ping/pong...</div>';
            testSocket.emit('ping');
            
            // Set timeout for ping response
            testTimeout = setTimeout(() => {
                if (!testResults.pingReceived) {
                    testResult.innerHTML += '<div style="color: #ff6b6b; margin-top: 4px;">⚠️ Ping timeout (no pong received)</div>';
                    finishTest();
                }
            }, 3000);
        });

        testSocket.on('connect_error', (error) => {
            testResult.innerHTML += `<div style="color: #ff6b6b; margin-top: 8px;">❌ Connection error: ${error.message || error}</div>`;
            finishTest();
        });

        testSocket.on('pong', (data) => {
            testResults.pingReceived = true;
            testResult.innerHTML += '<div style="color: #4caf50; margin-top: 4px;">✅ Ping/pong working</div>';
            if (testTimeout) clearTimeout(testTimeout);
            finishTest();
        });

        testSocket.on('connected', (data) => {
            testResults.eventsReceived.push('connected');
            testResult.innerHTML += `<div style="color: #4caf50; margin-top: 4px;">📨 Received 'connected' event</div>`;
        });

        // Overall timeout
        setTimeout(() => {
            if (!testResults.connected) {
                testResult.innerHTML += '<div style="color: #ff6b6b; margin-top: 8px;">❌ Connection timeout</div>';
                finishTest();
            }
        }, 5000);

        function finishTest() {
            testSocket.disconnect();
            
            // Summary
            testResult.innerHTML += '<div style="margin-top: 12px; padding-top: 12px; border-top: 1px solid #444;">';
            testResult.innerHTML += '<strong>📊 Test Summary:</strong><br>';
            testResult.innerHTML += `Connection: ${testResults.connected ? '✅' : '❌'}<br>`;
            testResult.innerHTML += `Ping/Pong: ${testResults.pingReceived ? '✅' : '❌'}<br>`;
            testResult.innerHTML += `Events: ${testResults.eventsReceived.length}`;
            testResult.innerHTML += '</div>';

            // Update button
            testBtn.disabled = false;
            testBtn.textContent = '🧪 Test WebSocket Connection';
            
            // Update result styling based on success
            if (testResults.connected && testResults.pingReceived) {
                testResult.style.border = '1px solid #4caf50';
            } else {
                testResult.style.border = '1px solid #ff6b6b';
            }
        }

        // Try to connect
        try {
            testSocket.connect();
        } catch (error) {
            testResult.innerHTML += `<div style="color: #ff6b6b; margin-top: 8px;">❌ Error: ${error.message}</div>`;
            finishTest();
        }
    }
};

// Make WebSocketManager available globally
window.WebSocketManager = WebSocketManager;



