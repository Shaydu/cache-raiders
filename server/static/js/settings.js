/**
 * Settings Manager - Handles admin panel settings
 * Note: LLM settings and Game Mode are now in separate components
 */
const SettingsManager = {
    locationUpdateInterval: null,
    locationUpdateIntervalTimer: null,

    /**
     * Initialize settings manager
     * Loads all settings from server to ensure UI reflects persisted values
     */
    async init() {
        console.log('🚀 [Settings] Initializing Settings Manager...');
        // Load location update interval
        await this.loadLocationUpdateInterval();

        // Initialize separate components (they handle their own loading)
        console.log('🔍 [Settings] Checking for LLMSettingsManager:', typeof window.LLMSettingsManager);
        if (window.LLMSettingsManager) {
            console.log('✅ [Settings] LLMSettingsManager found, calling init()...');
            await window.LLMSettingsManager.init();
        } else {
            console.error('❌ [Settings] LLMSettingsManager NOT found!');
        }

        console.log('🔍 [Settings] Checking for GameModeManager:', typeof window.GameModeManager);
        if (window.GameModeManager) {
            console.log('✅ [Settings] GameModeManager found, calling init()...');
            await window.GameModeManager.init();
        } else {
            console.warn('⚠️ [Settings] GameModeManager NOT found');
        }

        // Setup listeners after settings are loaded
        this.setupWebSocketListener();
        this.setupEventListeners();

        console.log('✅ Settings manager initialized');
    },

    /**
     * Setup event listeners for settings controls
     * Note: LLM and Game Mode listeners are handled by their respective components
     */
    setupEventListeners() {
        // Location update interval dropdown
        const locationIntervalSelect = document.getElementById('locationUpdateInterval');
        if (locationIntervalSelect) {
            locationIntervalSelect.addEventListener('change', () => {
                this.updateLocationInterval();
            });
        }
    },

    /**
     * Load location update interval from server
     */
    async loadLocationUpdateInterval() {
        try {
            const response = await fetch(`${Config.API_BASE}/api/settings/location-update-interval`);
            if (response.ok) {
                const data = await response.json();
                this.locationUpdateInterval = data.interval_ms;
                Config.USER_LOCATION_UPDATE_INTERVAL = data.interval_ms;
                
                // Update dropdown to reflect current value
                const dropdown = document.getElementById('locationUpdateInterval');
                if (dropdown) {
                    dropdown.value = data.interval_ms.toString();
                }
                
                // Restart location polling with new interval
                this.restartLocationPolling();
                
                console.log(`📍 Location update interval loaded: ${data.interval_ms}ms (${data.interval_seconds}s)`);
            } else {
                console.warn('Failed to load location update interval, using default');
                this.locationUpdateInterval = 1000; // Default 1 second
            }
        } catch (error) {
            console.warn('Error loading location update interval:', error);
            this.locationUpdateInterval = 1000; // Default 1 second
        }
    },

    /**
     * Update location update interval
     */
    async updateLocationInterval() {
        const dropdown = document.getElementById('locationUpdateInterval');
        if (!dropdown) return;
        
        const intervalMs = parseInt(dropdown.value);
        if (isNaN(intervalMs)) {
            console.error('Invalid interval value');
            return;
        }
        
        try {
            const response = await fetch(`${Config.API_BASE}/api/settings/location-update-interval`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ interval_ms: intervalMs })
            });
            
            if (response.ok) {
                const data = await response.json();
                this.locationUpdateInterval = data.interval_ms;
                Config.USER_LOCATION_UPDATE_INTERVAL = data.interval_ms;
                
                // Restart location polling with new interval
                this.restartLocationPolling();
                
                // Show success message
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Location update interval set to ${data.interval_seconds}s`,
                        'success'
                    );
                }
                
                console.log(`✅ Location update interval updated to ${data.interval_ms}ms (${data.interval_seconds}s)`);
            } else {
                // Try to parse JSON error response, but handle non-JSON responses gracefully
                let errorMessage = 'Unknown error';
                try {
                    const contentType = response.headers.get('content-type');
                    if (contentType && contentType.includes('application/json')) {
                        const error = await response.json();
                        errorMessage = error.error || error.message || 'Unknown error';
                    } else {
                        // If not JSON, try to get text
                        const text = await response.text();
                        errorMessage = text || `Server returned ${response.status} ${response.statusText}`;
                    }
                } catch (parseError) {
                    errorMessage = `Server returned ${response.status} ${response.statusText}`;
                }
                
                console.error('Failed to update location update interval:', errorMessage);
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Failed to update interval: ${errorMessage}`,
                        'error'
                    );
                }
            }
        } catch (error) {
            console.error('Error updating location update interval:', error);
            if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                UIManager.showStatusMessage(
                    'Failed to update interval: Network error',
                    'error'
                );
            }
        }
    },

    /**
     * Restart location polling with new interval
     */
    restartLocationPolling() {
        // Clear existing interval if it exists
        if (this.locationUpdateIntervalTimer) {
            clearInterval(this.locationUpdateIntervalTimer);
            this.locationUpdateIntervalTimer = null;
        }
        
        // Find and clear the existing interval in main.js
        // We'll need to store a reference to it in main.js
        if (window.App && window.App.locationUpdateIntervalId) {
            clearInterval(window.App.locationUpdateIntervalId);
            window.App.locationUpdateIntervalId = null;
        }
        
        // Start new interval
        if (UserLocationsManager && typeof UserLocationsManager.loadUserLocations === 'function') {
            window.App.locationUpdateIntervalId = setInterval(() => {
                UserLocationsManager.loadUserLocations();
            }, Config.USER_LOCATION_UPDATE_INTERVAL);
            
            console.log(`🔄 Restarted location polling with interval: ${Config.USER_LOCATION_UPDATE_INTERVAL}ms (${Config.USER_LOCATION_UPDATE_INTERVAL/1000}s)`);
        }
    },

    /**
     * Setup WebSocket listener for interval changes
     * Note: Game mode WebSocket listener is handled by GameModeManager
     */
    setupWebSocketListener() {
        if (window.WebSocketManager && WebSocketManager.socket) {
            WebSocketManager.socket.on('location_update_interval_changed', (data) => {
                this.locationUpdateInterval = data.interval_ms;
                Config.USER_LOCATION_UPDATE_INTERVAL = data.interval_ms;
                
                // Update dropdown
                const dropdown = document.getElementById('locationUpdateInterval');
                if (dropdown) {
                    dropdown.value = data.interval_ms.toString();
                }
                
                // Restart polling
                this.restartLocationPolling();
                
                console.log(`📍 Location update interval changed via WebSocket: ${data.interval_ms}ms (${data.interval_seconds}s)`);
            });
        }
    }
};

// Make SettingsManager available globally
window.SettingsManager = SettingsManager;
