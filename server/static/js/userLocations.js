/**
 * User Locations Manager - Handles user location markers and tracking
 */
const UserLocationsManager = {
    userLocationMarkers: {},
    userLocationCircles: {},
    playerMap: {},

    /**
     * Load user locations from API
     */
    async loadUserLocations() {
        try {
            const locations = await ApiService.userLocations.getAll();
            console.log('Loaded user locations:', Object.keys(locations).length, 'active users');

            // Get player names for device UUIDs
            try {
                const players = await ApiService.players.getAll();
                players.forEach(player => {
                    this.playerMap[player.device_uuid] = player.player_name || `Player ${player.device_uuid.substring(0, 8)}`;
                });
            } catch (error) {
                console.warn('Failed to load players for user locations:', error);
            }

            // Remove markers and circles for users that are no longer active
            const activeDeviceUuids = new Set(Object.keys(locations));
            Object.keys(this.userLocationMarkers).forEach(deviceUuid => {
                if (!activeDeviceUuids.has(deviceUuid)) {
                    MapManager.getMap().removeLayer(this.userLocationMarkers[deviceUuid]);
                    delete this.userLocationMarkers[deviceUuid];
                }
            });
            Object.keys(this.userLocationCircles).forEach(deviceUuid => {
                if (!activeDeviceUuids.has(deviceUuid)) {
                    MapManager.getMap().removeLayer(this.userLocationCircles[deviceUuid]);
                    delete this.userLocationCircles[deviceUuid];
                }
            });

            // Add or update markers for active users
            Object.entries(locations).forEach(([deviceUuid, location]) => {
                let playerName = this.playerMap[deviceUuid] || `User ${deviceUuid.substring(0, 8)}`;
                const lat = location.latitude;
                const lng = location.longitude;
                const accuracy = location.accuracy;
                const heading = location.heading;
                const updatedAt = new Date(location.updated_at).toLocaleTimeString();

                console.log(`📍 Processing user location: ${deviceUuid.substring(0, 8)}... (${playerName}) at (${lat.toFixed(6)}, ${lng.toFixed(6)})`);

                // If player name not in cache, fetch it asynchronously
                if (!this.playerMap[deviceUuid]) {
                    this.fetchPlayerName(deviceUuid, lat, lng, accuracy, heading, updatedAt);
                }

                // Create or update marker and circle
                this.createOrUpdateUserMarker(deviceUuid, lat, lng, accuracy, heading, updatedAt, playerName);
            });

            // Mark players as connected when we load their locations
            Object.keys(this.userLocationMarkers).forEach(deviceUuid => {
                WebSocketManager.markPlayerConnected(deviceUuid);
            });
        } catch (error) {
            console.warn('Error loading user locations:', error);
        }
    },

    /**
     * Fetch player name asynchronously
     */
    async fetchPlayerName(deviceUuid, lat, lng, accuracy, heading, updatedAt) {
        try {
            const player = await ApiService.players.getById(deviceUuid);
            if (player && player.player_name) {
                this.playerMap[deviceUuid] = player.player_name;
                console.log(`✅ Fetched player name for ${deviceUuid.substring(0, 8)}...: ${player.player_name}`);
                // Update marker with actual player name
                if (this.userLocationMarkers[deviceUuid]) {
                    this.updateMarkerName(deviceUuid, player.player_name, lat, lng, accuracy, heading, updatedAt);
                }
            } else {
                this.playerMap[deviceUuid] = `User ${deviceUuid.substring(0, 8)}`;
            }
        } catch (error) {
            console.warn(`⚠️ Failed to fetch player name for ${deviceUuid.substring(0, 8)}...:`, error);
            this.playerMap[deviceUuid] = `User ${deviceUuid.substring(0, 8)}`;
        }
    },

    /**
     * Update marker name
     */
    updateMarkerName(deviceUuid, playerName, lat, lng, accuracy, heading, updatedAt) {
        const marker = this.userLocationMarkers[deviceUuid];
        if (!marker) return;

        const existingTooltip = marker.getTooltip();
        if (existingTooltip) {
            existingTooltip.setContent(playerName);
        } else {
            marker.unbindTooltip();
            marker.bindTooltip(playerName, {
                permanent: true,
                direction: 'bottom',
                offset: [0, 12],
                className: 'user-location-label',
                opacity: 1.0
            }).openTooltip();
        }

        marker.setPopupContent(`
            <strong>📍 ${playerName}</strong><br>
            <span style="color: #2196F3; font-weight: bold;">● User Location</span><br>
            Location: ${lat.toFixed(6)}, ${lng.toFixed(6)}<br>
            ${accuracy ? `Accuracy: ${accuracy.toFixed(1)}m<br>` : ''}
            ${heading !== null && heading !== undefined ? `Heading: ${heading.toFixed(0)}°<br>` : ''}
            Updated: ${updatedAt}
        `);
    },

    /**
     * Update or create user location marker from WebSocket event
     */
    updateUserLocationMarker(data) {
        const deviceUuid = data.device_uuid;
        const lat = data.latitude;
        const lng = data.longitude;
        const accuracy = data.accuracy;
        const heading = data.heading;
        const updatedAt = new Date(data.updated_at).toLocaleTimeString();

        // Get player name (load if not cached)
        if (!this.playerMap[deviceUuid]) {
            this.fetchPlayerName(deviceUuid, lat, lng, accuracy, heading, updatedAt).then(() => {
                const playerName = this.playerMap[deviceUuid] || `User ${deviceUuid.substring(0, 8)}`;
                this.createOrUpdateUserMarker(deviceUuid, lat, lng, accuracy, heading, updatedAt, playerName);
            });
        } else {
            const playerName = this.playerMap[deviceUuid];
            this.createOrUpdateUserMarker(deviceUuid, lat, lng, accuracy, heading, updatedAt, playerName);
        }
    },

    /**
     * Helper function to create or update user marker
     */
    createOrUpdateUserMarker(deviceUuid, lat, lng, accuracy, heading, updatedAt, playerName) {
        // Update or create marker
        if (this.userLocationMarkers[deviceUuid]) {
            // Update existing marker position
            this.userLocationMarkers[deviceUuid].setLatLng([lat, lng]);
            if (heading !== null && heading !== undefined) {
                const icon = L.divIcon({
                    className: 'user-location-marker',
                    html: this.createUserLocationIcon(heading),
                    iconSize: [22, 22],
                    iconAnchor: [11, 11]
                });
                this.userLocationMarkers[deviceUuid].setIcon(icon);
            }
            // Update popup
            this.userLocationMarkers[deviceUuid].setPopupContent(`
                <strong>📍 ${playerName}</strong><br>
                <span style="color: #2196F3; font-weight: bold;">● User Location</span><br>
                Location: ${lat.toFixed(6)}, ${lng.toFixed(6)}<br>
                ${accuracy ? `Accuracy: ${accuracy.toFixed(1)}m<br>` : ''}
                ${heading !== null && heading !== undefined ? `Heading: ${heading.toFixed(0)}°<br>` : ''}
                Updated: ${updatedAt}
            `);
            // Update tooltip
            const existingTooltip = this.userLocationMarkers[deviceUuid].getTooltip();
            if (existingTooltip) {
                existingTooltip.setContent(playerName);
                if (!existingTooltip.isOpen()) {
                    this.userLocationMarkers[deviceUuid].openTooltip();
                }
            } else {
                this.userLocationMarkers[deviceUuid].bindTooltip(playerName, {
                    permanent: true,
                    direction: 'bottom',
                    offset: [0, 12],
                    className: 'user-location-label',
                    opacity: 1.0
                }).openTooltip();
            }
        } else {
            // Create new marker
            const icon = L.divIcon({
                className: 'user-location-marker',
                html: this.createUserLocationIcon(heading),
                iconSize: [22, 22],
                iconAnchor: [11, 11]
            });

            const marker = L.marker([lat, lng], {
                icon: icon,
                zIndexOffset: 1000
            })
                .addTo(MapManager.getMap())
                .bindPopup(`
                    <strong>📍 ${playerName}</strong><br>
                    <span style="color: #2196F3; font-weight: bold;">● User Location</span><br>
                    Location: ${lat.toFixed(6)}, ${lng.toFixed(6)}<br>
                    ${accuracy ? `Accuracy: ${accuracy.toFixed(1)}m<br>` : ''}
                    ${heading !== null && heading !== undefined ? `Heading: ${heading.toFixed(0)}°<br>` : ''}
                    Updated: ${updatedAt}
                `)
                .bindTooltip(playerName, {
                    permanent: true,
                    direction: 'bottom',
                    offset: [0, 12],
                    className: 'user-location-label',
                    opacity: 1.0
                })
                .openTooltip();

            this.userLocationMarkers[deviceUuid] = marker;
            console.log(`✅ Added blue dot for user: ${playerName} at (${lat}, ${lng})`);
        }

        // Update or create accuracy circle
        if (accuracy && accuracy > 0) {
            if (this.userLocationCircles[deviceUuid]) {
                this.userLocationCircles[deviceUuid].setLatLng([lat, lng]);
                this.userLocationCircles[deviceUuid].setRadius(accuracy);
            } else {
                const circle = L.circle([lat, lng], {
                    radius: accuracy,
                    color: '#2196F3',
                    fillColor: '#2196F3',
                    fillOpacity: 0.2,
                    weight: 2,
                    opacity: 0.6
                }).addTo(MapManager.getMap());

                this.userLocationCircles[deviceUuid] = circle;
                console.log(`✅ Added blue circle for user: ${playerName} with accuracy: ${accuracy.toFixed(1)}m`);
            }
        } else {
            if (this.userLocationCircles[deviceUuid]) {
                MapManager.getMap().removeLayer(this.userLocationCircles[deviceUuid]);
                delete this.userLocationCircles[deviceUuid];
            }
        }
    },

    /**
     * Create user location icon with optional heading arrow
     */
    createUserLocationIcon(heading) {
        if (heading !== null && heading !== undefined) {
            return `
                <div style="
                    width: 22px;
                    height: 22px;
                    background: #2196F3;
                    border: 3px solid #fff;
                    border-radius: 50%;
                    box-shadow: 0 0 12px rgba(33, 150, 243, 0.8), 0 0 6px rgba(33, 150, 243, 0.4);
                    position: relative;
                    transform: rotate(${heading}deg);
                    z-index: 1000;
                ">
                    <div style="
                        position: absolute;
                        top: -2px;
                        left: 50%;
                        transform: translateX(-50%);
                        width: 0;
                        height: 0;
                        border-left: 4px solid transparent;
                        border-right: 4px solid transparent;
                        border-top: 8px solid #fff;
                    "></div>
                </div>
            `;
        } else {
            return `
                <div style="
                    background: #2196F3;
                    width: 22px;
                    height: 22px;
                    border-radius: 50%;
                    border: 3px solid #fff;
                    box-shadow: 0 0 12px rgba(33, 150, 243, 0.8), 0 0 6px rgba(33, 150, 243, 0.4);
                    z-index: 1000;
                "></div>
            `;
        }
    }
};

// Make UserLocationsManager available globally
window.UserLocationsManager = UserLocationsManager;



