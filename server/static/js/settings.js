/**
 * Settings Manager - Handles admin panel settings
 */
const SettingsManager = {
    locationUpdateInterval: null,
    locationUpdateIntervalTimer: null,

    /**
     * Initialize settings manager
     */
    async init() {
        await this.loadLocationUpdateInterval();
        this.setupWebSocketListener();
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
                const error = await response.json();
                console.error('Failed to update location update interval:', error);
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Failed to update interval: ${error.error || 'Unknown error'}`,
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

