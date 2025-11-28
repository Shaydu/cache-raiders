/**
 * Diagnostics Manager - Handles connection diagnostics and two-way ping
 */
const DiagnosticsManager = {
    socket: null,
    pingResults: [],
    maxResults: 50,
    connectedClients: [],

    /**
     * Initialize diagnostics manager
     */
    init() {
        this.socket = WebSocketManager.socket;
        this.setupEventListeners();
    },

    /**
     * Setup WebSocket event listeners for diagnostics
     */
    setupEventListeners() {
        if (!this.socket) {
            console.warn('⚠️ Diagnostics: WebSocket not available');
            return;
        }

        // Listen for diagnostic pong from server
        this.socket.on('diagnostic_pong', (data) => {
            this.handleServerPong(data);
        });

        // Listen for connected clients list
        this.socket.on('connected_clients_list', (data) => {
            this.handleConnectedClientsList(data);
        });

        // Listen for admin ping responses from clients
        this.socket.on('admin_ping_response', (data) => {
            this.handleClientPong(data);
        });

        // Listen for ping errors
        this.socket.on('admin_ping_error', (data) => {
            this.handlePingError(data);
        });
    },

    /**
     * Ping the server and measure latency
     */
    async pingServer() {
        if (!this.socket || !this.socket.connected) {
            this.showResult('error', 'Not connected to WebSocket server');
            return;
        }

        const pingId = `server_${Date.now()}`;
        const startTime = Date.now();
        const timestamp = new Date().toISOString();

        // Set up timeout
        const timeout = setTimeout(() => {
            this.showResult('error', `Server ping timeout (ping_id: ${pingId})`);
        }, 5000);

        // Set up one-time listener for pong
        const pongHandler = (data) => {
            if (data.ping_id === pingId) {
                clearTimeout(timeout);
                this.socket.off('diagnostic_pong', pongHandler);
                
                const endTime = Date.now();
                const latency = endTime - startTime;
                
                const result = {
                    type: 'server',
                    ping_id: pingId,
                    latency_ms: latency,
                    timestamp: timestamp,
                    server_timestamp: data.server_timestamp
                };
                
                this.addResult(result);
                this.showResult('success', `Server ping: ${latency}ms`);
            }
        };

        this.socket.on('diagnostic_pong', pongHandler);
        this.socket.emit('diagnostic_ping', {
            ping_id: pingId,
            timestamp: timestamp
        });
    },

    /**
     * Ping a specific client device
     */
    async pingClient(deviceUuid) {
        if (!this.socket || !this.socket.connected) {
            this.showResult('error', 'Not connected to WebSocket server');
            return;
        }

        const pingId = `client_${deviceUuid}_${Date.now()}`;
        const startTime = Date.now();
        const timestamp = new Date().toISOString();

        // Set up timeout
        const timeout = setTimeout(() => {
            this.showResult('error', `Client ping timeout for ${deviceUuid.substring(0, 8)}...`);
            this.socket.off('admin_ping_response', pongHandler);
        }, 10000); // 10 second timeout for client pings

        // Set up one-time listener for pong
        const pongHandler = (data) => {
            if (data.ping_id === pingId) {
                clearTimeout(timeout);
                this.socket.off('admin_ping_response', pongHandler);
                
                const endTime = Date.now();
                const latency = endTime - startTime;
                
                const result = {
                    type: 'client',
                    ping_id: pingId,
                    device_uuid: deviceUuid,
                    latency_ms: latency,
                    timestamp: timestamp,
                    client_timestamp: data.client_timestamp,
                    server_timestamp: data.server_timestamp
                };
                
                this.addResult(result);
                this.showResult('success', `Client ${deviceUuid.substring(0, 8)}... ping: ${latency}ms`);
            }
        };

        this.socket.on('admin_ping_response', pongHandler);
        this.socket.emit('admin_ping_client', {
            device_uuid: deviceUuid,
            ping_id: pingId,
            timestamp: timestamp
        });
    },

    /**
     * Ping all connected clients
     */
    async pingAllClients() {
        // First get list of connected clients
        if (!this.socket || !this.socket.connected) {
            this.showResult('error', 'Not connected to WebSocket server');
            return;
        }

        // Request connected clients list
        this.socket.emit('get_connected_clients');
        
        // Wait for response and ping all
        const pingAll = () => {
            // Get connected clients from the last received list
            const clientsEl = document.getElementById('diagnosticConnectedClients');
            if (!clientsEl) {
                this.showResult('error', 'Could not find connected clients list');
                return;
            }

            // Extract device UUIDs from the UI
            const clientItems = clientsEl.querySelectorAll('.diagnostic-client-item');
            if (clientItems.length === 0) {
                this.showResult('info', 'No connected clients to ping');
                return;
            }

            this.showResult('info', `Pinging ${clientItems.length} client(s)...`);
            
            // Extract device UUIDs from button onclick handlers
            clientItems.forEach(item => {
                const button = item.querySelector('button');
                if (button && button.onclick) {
                    // Extract UUID from onclick string
                    const onclickStr = button.getAttribute('onclick') || '';
                    const uuidMatch = onclickStr.match(/pingClient\('([^']+)'\)/);
                    if (uuidMatch && uuidMatch[1]) {
                        this.pingClient(uuidMatch[1]);
                    }
                }
            });
        };

        // Wait a bit for the connected clients list to update
        setTimeout(pingAll, 1000);
    },

    /**
     * Handle server pong response
     */
    handleServerPong(data) {
        // Already handled in pingServer() via event listener
    },

    /**
     * Handle client pong response
     */
    handleClientPong(data) {
        // Already handled in pingClient() via event listener
    },

    /**
     * Handle connected clients list
     */
    handleConnectedClientsList(data) {
        console.log('📡 Connected clients:', data.clients);
        this.updateConnectedClientsUI(data.clients);
        // Store for later use
        this.connectedClients = data.clients;
    },

    /**
     * Handle ping error
     */
    handlePingError(data) {
        this.showResult('error', `Ping error: ${data.error} (device: ${data.device_uuid?.substring(0, 8) || 'unknown'}...)`);
    },

    /**
     * Add result to history
     */
    addResult(result) {
        this.pingResults.unshift(result);
        if (this.pingResults.length > this.maxResults) {
            this.pingResults.pop();
        }
        this.updateResultsUI();
    },

    /**
     * Show result message
     */
    showResult(type, message) {
        const resultEl = document.getElementById('diagnosticResult');
        if (!resultEl) return;

        resultEl.style.display = 'block';
        resultEl.className = `diagnostic-result ${type}`;
        resultEl.textContent = message;

        // Auto-hide after 5 seconds for success/info
        if (type === 'success' || type === 'info') {
            setTimeout(() => {
                if (resultEl.textContent === message) {
                    resultEl.style.display = 'none';
                }
            }, 5000);
        }
    },

    /**
     * Update results UI
     */
    updateResultsUI() {
        const resultsEl = document.getElementById('diagnosticResults');
        if (!resultsEl) return;

        if (this.pingResults.length === 0) {
            resultsEl.innerHTML = '<div class="loading">No ping results yet</div>';
            return;
        }

        resultsEl.innerHTML = this.pingResults.map(result => {
            const time = new Date(result.timestamp).toLocaleTimeString();
            let typeLabel, latencyDisplay, deviceInfo = '';
            
            if (result.type === 'server') {
                typeLabel = '🖥️ Server';
                const latencyColor = result.latency_ms < 50 ? '#4caf50' : result.latency_ms < 200 ? '#ff9800' : '#f44336';
                latencyDisplay = `<span style="color: ${latencyColor}; font-weight: bold;">${result.latency_ms}ms</span>`;
            } else if (result.type === 'client') {
                typeLabel = '📱 Client';
                deviceInfo = result.device_uuid ? ` (${result.device_uuid.substring(0, 8)}...)` : '';
                const latencyColor = result.latency_ms < 50 ? '#4caf50' : result.latency_ms < 200 ? '#ff9800' : '#f44336';
                latencyDisplay = `<span style="color: ${latencyColor}; font-weight: bold;">${result.latency_ms}ms</span>`;
            } else if (result.type === 'port') {
                typeLabel = '🔌 Port';
                deviceInfo = ` ${result.host}:${result.port}`;
                if (result.reachable) {
                    latencyDisplay = '<span style="color: #4caf50; font-weight: bold;">✅ Reachable</span>';
                } else {
                    latencyDisplay = `<span style="color: #f44336; font-weight: bold;">❌ Blocked</span>`;
                }
            } else {
                typeLabel = '❓ Unknown';
                latencyDisplay = result.latency_ms ? `${result.latency_ms}ms` : 'N/A';
            }

            return `
                <div class="diagnostic-result-item">
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">
                        <span style="font-weight: bold;">${typeLabel}${deviceInfo}</span>
                        ${latencyDisplay}
                    </div>
                    ${result.error ? `<div style="font-size: 11px; color: #f44336; margin-top: 4px;">Error: ${result.error}</div>` : ''}
                    <div style="font-size: 11px; color: #999;">${time}</div>
                </div>
            `;
        }).join('');
    },

    /**
     * Update connected clients UI
     */
    updateConnectedClientsUI(clients) {
        const clientsEl = document.getElementById('diagnosticConnectedClients');
        if (!clientsEl) return;

        if (clients.length === 0) {
            clientsEl.innerHTML = '<div class="loading">No connected clients</div>';
            return;
        }

        clientsEl.innerHTML = clients.map(client => {
            const shortUuid = client.device_uuid.substring(0, 8) + '...';
            return `
                <div class="diagnostic-client-item" style="display: flex; justify-content: space-between; align-items: center; padding: 8px; background: #1a1a1a; border-radius: 4px; margin-bottom: 6px;">
                    <span style="font-family: monospace; font-size: 12px;">${shortUuid}</span>
                    <button onclick="DiagnosticsManager.pingClient('${client.device_uuid}')" 
                            style="background: #4caf50; color: #fff; border: none; border-radius: 4px; padding: 4px 8px; font-size: 11px; cursor: pointer;">
                        Ping
                    </button>
                </div>
            `;
        }).join('');
    },

    /**
     * Test port connectivity
     */
    async testPort(host, port) {
        try {
            const response = await fetch(`${Config.API_BASE}/api/debug/test-port?host=${encodeURIComponent(host)}&port=${port}`);
            const data = await response.json();
            
            const result = {
                type: 'port',
                host: host,
                port: port,
                reachable: data.reachable,
                latency_ms: null,
                timestamp: data.test_timestamp,
                error: data.error
            };
            
            this.addResult(result);
            
            if (data.reachable) {
                this.showResult('success', `Port ${port} on ${host} is reachable`);
            } else {
                this.showResult('error', `Port ${port} on ${host} is not reachable: ${data.error || 'Unknown error'}`);
            }
            
            return data;
        } catch (error) {
            this.showResult('error', `Port test failed: ${error.message}`);
            return { reachable: false, error: error.message };
        }
    },

    /**
     * Test multiple ports
     */
    async testMultiplePorts(host, ports = [5001, 5000, 8080, 3000, 8000]) {
        this.showResult('info', `Testing ${ports.length} ports on ${host}...`);
        
        const results = [];
        for (const port of ports) {
            const result = await this.testPort(host, port);
            results.push({ port, ...result });
            await new Promise(resolve => setTimeout(resolve, 500)); // Small delay between tests
        }
        
        const reachablePorts = results.filter(r => r.reachable);
        if (reachablePorts.length > 0) {
            this.showResult('success', `${reachablePorts.length} of ${ports.length} ports are reachable`);
        } else {
            this.showResult('error', `None of the tested ports are reachable. This may indicate router/firewall blocking.`);
        }
        
        return results;
    },

    /**
     * Run full diagnostic suite
     */
    async runFullDiagnostic() {
        this.showResult('info', 'Running full diagnostic...');
        
        // Clear previous results
        this.pingResults = [];
        this.updateResultsUI();

        // 1. Ping server
        await this.pingServer();
        await new Promise(resolve => setTimeout(resolve, 1000));

        // 2. Test port connectivity
        const serverURL = new URL(Config.API_BASE);
        const host = serverURL.hostname;
        const port = parseInt(serverURL.port) || (serverURL.protocol === 'https:' ? 443 : 80);
        
        await this.testPort(host, port);
        await new Promise(resolve => setTimeout(resolve, 1000));

        // 3. Test common ports
        await this.testMultiplePorts(host);
        await new Promise(resolve => setTimeout(resolve, 1000));

        // 4. Get and ping all clients
        await this.pingAllClients();
        
        this.showResult('success', 'Full diagnostic complete');
    },

    /**
     * Refresh connected clients list
     */
    refreshConnectedClients() {
        if (!this.socket || !this.socket.connected) {
            this.showResult('error', 'Not connected to WebSocket server');
            return;
        }
        
        this.showResult('info', 'Refreshing connected clients list...');
        this.socket.emit('get_connected_clients');
        
        // Update UI after a short delay to show loading state
        const clientsEl = document.getElementById('diagnosticConnectedClients');
        if (clientsEl) {
            clientsEl.innerHTML = '<div class="loading">Refreshing...</div>';
        }
    },

    /**
     * Clear results
     */
    clearResults() {
        this.pingResults = [];
        this.updateResultsUI();
        this.showResult('info', 'Results cleared');
    }
};

// Make DiagnosticsManager available globally
window.DiagnosticsManager = DiagnosticsManager;

