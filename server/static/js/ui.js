/**
 * UI Utilities - Status messages and common UI operations
 */
const UI = {
    /**
     * Safely update DOM element (defers to next frame to avoid render warnings)
     */
    safeUpdateDOM(callback) {
        requestAnimationFrame(() => {
            requestAnimationFrame(callback);
        });
    },

    /**
     * Show status message
     */
    showStatus(message, type = 'info') {
        const statusEl = document.getElementById('statusMessage');
        if (!statusEl) return;

        this.safeUpdateDOM(() => {
            statusEl.innerHTML = `<div class="status ${type}">${message}</div>`;

            // Auto-hide after configured duration
            setTimeout(() => {
                this.safeUpdateDOM(() => {
                    statusEl.innerHTML = '';
                });
            }, Config.STATUS_MESSAGE_DURATION);
        });
    },

    /**
     * Center map on browser's current location
     */
    centerOnBrowserLocation() {
        if (!navigator.geolocation) {
            UI.showStatus('Geolocation is not supported by this browser.', 'error');
            return;
        }

        navigator.geolocation.getCurrentPosition(
            (pos) => {
                const lat = pos.coords.latitude;
                const lng = pos.coords.longitude;
                MapManager.setView([lat, lng], 17);
                UI.showStatus(`Centered map on your location: ${lat.toFixed(5)}, ${lng.toFixed(5)}`, 'success');
            },
            (err) => {
                UI.showStatus(`Unable to get your location: ${err.message}`, 'error');
            }
        );
    },

    /**
     * Center map on connected user's location (from iOS app)
     */
    async centerOnUserLocation() {
        // First, try to refresh user locations in case they haven't loaded yet
        try {
            await UserLocationsManager.loadUserLocations();
        } catch (error) {
            console.warn('Failed to refresh user locations:', error);
        }

        const userMarkers = UserLocationsManager.userLocationMarkers;
        const userCount = Object.keys(userMarkers).length;

        if (userCount === 0) {
            UI.showStatus('No connected users found. Make sure the iOS app is connected and has sent its location.', 'error');
            return;
        }

        // If multiple users, center on the first one (most recently updated)
        // Get all user locations sorted by most recent
        const userLocations = Object.entries(userMarkers).map(([deviceUuid, marker]) => {
            const latlng = marker.getLatLng();
            return {
                deviceUuid: deviceUuid,
                lat: latlng.lat,
                lng: latlng.lng,
                playerName: UserLocationsManager.playerMap[deviceUuid] || `User ${deviceUuid.substring(0, 8)}`
            };
        });

        // Use the first user's location (or could sort by updated_at if available)
        const firstUser = userLocations[0];
        const lat = firstUser.lat;
        const lng = firstUser.lng;

        // Center map on user location with appropriate zoom level
        MapManager.setView([lat, lng], 17);
        
        if (userCount === 1) {
            UI.showStatus(`Centered map on ${firstUser.playerName}'s location: ${lat.toFixed(5)}, ${lng.toFixed(5)}`, 'success');
        } else {
            UI.showStatus(`Centered map on ${firstUser.playerName}'s location (${userCount} users connected): ${lat.toFixed(5)}, ${lng.toFixed(5)}`, 'success');
        }
    },

    /**
     * Copy text to clipboard
     */
    async copyToClipboard(text) {
        try {
            await navigator.clipboard.writeText(text);
            UI.showStatus('Copied to clipboard!', 'success');
            return true;
        } catch (err) {
            // Fallback for older browsers
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.select();
            try {
                document.execCommand('copy');
                document.body.removeChild(textarea);
                UI.showStatus('Copied to clipboard!', 'success');
                return true;
            } catch (e) {
                document.body.removeChild(textarea);
                UI.showStatus('Failed to copy. Please copy manually.', 'error');
                return false;
            }
        }
    }
};

// Make UI available globally
window.UI = UI;

