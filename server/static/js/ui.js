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
     * Center map on top user from leaderboard
     */
    async centerOnUserLocation() {
        try {
            // Get stats to find the top user from leaderboard
            const stats = await ApiService.stats.get();
            const topFinders = stats.top_finders || [];
            
            if (topFinders.length === 0) {
                UI.showStatus('No players found on leaderboard.', 'error');
                return;
            }

            // Get the top user (first in leaderboard)
            const topUser = topFinders[0];
            const topUserDeviceUuid = topUser.device_uuid;
            const topUserName = topUser.user || `User ${topUserDeviceUuid.substring(0, 8)}`;

            // Refresh user locations to make sure we have the latest
            await UserLocationsManager.loadUserLocations();

            // Find the top user's location marker
            const userMarkers = UserLocationsManager.userLocationMarkers;
            const topUserMarker = userMarkers[topUserDeviceUuid];

            if (!topUserMarker) {
                UI.showStatus(`${topUserName} is not currently connected or has not sent their location.`, 'error');
                return;
            }

            // Get the location from the marker
            const latlng = topUserMarker.getLatLng();
            const lat = latlng.lat;
            const lng = latlng.lng;

            // Center map on top user's location with appropriate zoom level
            MapManager.setView([lat, lng], 17);
            UI.showStatus(`Centered map on top player ${topUserName}'s location: ${lat.toFixed(5)}, ${lng.toFixed(5)}`, 'success');
        } catch (error) {
            console.error('Error centering on top user:', error);
            UI.showStatus('Error centering on top user: ' + error.message, 'error');
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

