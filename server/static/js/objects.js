/**
 * Objects Manager - Handles object CRUD operations and display
 */
const ObjectsManager = {
    markers: {},
    markerData: {}, // Store marker data for resizing
    storyMarkers: {}, // Store story mode markers separately

    /**
     * Load all objects and display on map
     */
    async loadObjects() {
        try {
            const objects = await ApiService.objects.getAll(true);

            // Clear existing markers
            Object.values(this.markers).forEach(marker => {
                MapManager.getMap().removeLayer(marker);
            });
            this.markers = {};
            this.markerData = {};

            // ADMIN PANEL: Always show all objects regardless of game mode
            // (Story mode filtering only applies to iOS app, not admin panel)
            const filteredObjects = objects;

            // Get current zoom level
            const currentZoom = MapManager.getMap() ? MapManager.getMap().getZoom() : 15;

            // Add markers for each object
            filteredObjects.forEach(obj => {
                this.addObjectMarker(obj, currentZoom);
            });

            // Update objects list in sidebar (use filtered objects)
            this.updateObjectsList(filteredObjects);
        } catch (error) {
            console.error('Error loading objects:', error);
            UI.showStatus('Error loading objects: ' + error.message, 'error');
        }
    },

    /**
     * Add object marker to map
     */
    addObjectMarker(obj, zoom = 15) {
        // Use the stored name from the database (what admin typed when creating)
        const displayName = obj.name || obj.type;

        // Calculate marker size based on zoom
        const markerSize = MapManager.calculateMarkerSize(zoom, obj.collected);

        // Store marker data for resizing
        this.markerData[obj.id] = {
            collected: obj.collected,
            displayName: displayName,
            obj: obj
        };

        // Create icon based on calculated size
        const icon = this.createMarkerIcon(obj.collected, markerSize, obj);

        const marker = L.marker([obj.latitude, obj.longitude], { icon })
            .addTo(MapManager.getMap())
            .bindPopup(`
                <strong>${displayName}</strong><br>
                Type: ${obj.type}<br>
                Radius: ${obj.radius}m<br>
                ${obj.collected ? `<span style="color: #ff6b6b; font-weight: bold;">✓ Collected</span><br>Found by: ${obj.found_by || 'Unknown'}` : '<span style="color: #ffd700; font-weight: bold;">● Available</span>'}
            `);

        // Add click handler to open modal
        marker.on('click', () => {
            ModalManager.openObjectModal(obj.id);
        });

        this.markers[obj.id] = marker;
    },

    /**
     * Create marker icon with specified size
     */
    createMarkerIcon(isCollected, size, obj = null) {
        let iconHtml;
        const anchorOffset = size / 2;

        // Check if this is an NPC (Dead Men's Secrets mode)
        const isNPC = obj && obj.id && obj.id.startsWith('npc_');
        const isSkeleton = isNPC && (obj.name && (obj.name.includes('Bones') || obj.name.includes('skeleton')));

        // Check if this is an NFC-placed object
        const isNFCObject = obj && obj.id && obj.id.startsWith('nfc_');

        // Check if this is an AR-placed object (not created by admin web UI)
        const isARObject = obj && obj.created_by && obj.created_by !== 'admin-web-ui';

        // Check if this is an admin-placed object (created by admin web UI)
        const isAdminObject = obj && obj.created_by && obj.created_by === 'admin-web-ui';

        if (isNPC) {
            // NPC icon - skull for skeleton, person for others
            const iconColor = '#ffd700'; // Gold color for NPCs
            const borderColor = '#b8860b';
            const borderWidth = Math.max(2, Math.min(4, size / 6));
            const iconSymbol = isSkeleton ? '💀' : '👤';
            iconHtml = `
                <div style="
                    background: ${iconColor};
                    width: ${size}px;
                    height: ${size}px;
                    border-radius: 50%;
                    border: ${borderWidth}px solid ${borderColor};
                    box-shadow: 0 0 ${size/2}px rgba(255, 215, 0, 0.6);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: ${size * 0.6}px;
                ">${iconSymbol}</div>
            `;
        } else if (isNFCObject) {
            // NFC object icon - blue circle with white 'N'
            const markerColor = isCollected ? '#ff6b6b' : '#4a90e2'; // Red if found, blue if unfound
            const borderColor = isCollected ? '#c62828' : '#1565c0';
            const borderWidth = Math.max(2, Math.min(4, size / 6));
            iconHtml = `
                <div style="
                    background: ${markerColor};
                    width: ${size}px;
                    height: ${size}px;
                    border-radius: 50%;
                    border: ${borderWidth}px solid ${borderColor};
                    box-shadow: 0 0 ${size/2}px rgba(74, 144, 226, 0.6);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: ${size * 0.6}px;
                    color: white;
                    font-weight: bold;
                ">N</div>
            `;
        } else if (isARObject) {
            // AR object icon - purple circle with white 'AR'
            const markerColor = isCollected ? '#ff6b6b' : '#9c27b0'; // Red if found, purple if unfound
            const borderColor = isCollected ? '#c62828' : '#7b1fa2';
            const borderWidth = Math.max(2, Math.min(4, size / 6));
            iconHtml = `
                <div style="
                    background: ${markerColor};
                    width: ${size}px;
                    height: ${size}px;
                    border-radius: 50%;
                    border: ${borderWidth}px solid ${borderColor};
                    box-shadow: 0 0 ${size/2}px rgba(156, 39, 176, 0.6);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: ${size * 0.4}px; // Smaller font for 'AR'
                    color: white;
                    font-weight: bold;
                ">AR</div>
            `;
        } else if (isAdminObject) {
            // Admin object icon - green circle with white 'A'
            const markerColor = isCollected ? '#ff6b6b' : '#4caf50'; // Red if found, green if unfound
            const borderColor = isCollected ? '#c62828' : '#2e7d32';
            const borderWidth = Math.max(2, Math.min(4, size / 6));
            iconHtml = `
                <div style="
                    background: ${markerColor};
                    width: ${size}px;
                    height: ${size}px;
                    border-radius: 50%;
                    border: ${borderWidth}px solid ${borderColor};
                    box-shadow: 0 0 ${size/2}px rgba(76, 175, 80, 0.6);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: ${size * 0.6}px;
                    color: white;
                    font-weight: bold;
                ">A</div>
            `;
        } else if (isCollected) {
            // Stylized red X for found treasure
            // Adjust stroke width based on size to keep proportions
            const strokeWidth = Math.max(2, Math.min(5, size / 6));
            iconHtml = `
                <div style="
                    width: ${size}px;
                    height: ${size}px;
                    position: relative;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                ">
                    <svg width="${size}" height="${size}" viewBox="0 0 24 24" style="filter: drop-shadow(0 0 ${size/6}px rgba(255, 0, 0, 0.8));">
                        <path d="M2 2 L22 22 M22 2 L2 22"
                              stroke="#ff0000"
                              stroke-width="${strokeWidth}"
                              stroke-linecap="round"
                              stroke-linejoin="round"/>
                    </svg>
                </div>
            `;
        } else {
            // Gold circle for unfound treasure
            const markerColor = '#ffd700';
            const borderColor = '#b8860b';
            const borderWidth = Math.max(2, Math.min(4, size / 6));
            iconHtml = `<div style="background: ${markerColor}; width: ${size}px; height: ${size}px; border-radius: 50%; border: ${borderWidth}px solid ${borderColor}; box-shadow: 0 0 ${size/2}px rgba(255, 215, 0, 0.6);"></div>`;
        }

        return L.divIcon({
            className: 'object-marker',
            html: iconHtml,
            iconSize: [size, size],
            iconAnchor: [anchorOffset, anchorOffset]
        });
    },

    /**
     * Update all marker sizes based on current zoom level
     */
    updateMarkerSizes(zoom) {
        Object.keys(this.markers).forEach(markerId => {
            const marker = this.markers[markerId];
            const markerInfo = this.markerData[markerId];

            if (!marker || !markerInfo) return;

            // Calculate new size
            const newSize = MapManager.calculateMarkerSize(zoom, markerInfo.collected);

            // Create new icon with updated size
            const newIcon = this.createMarkerIcon(markerInfo.collected, newSize, markerInfo.obj);

            // Update marker icon
            marker.setIcon(newIcon);
        });
    },

    /**
     * Update objects list in sidebar
     */
    updateObjectsList(objects) {
        const listEl = document.getElementById('objectsList');
        if (!listEl) return;

        // Defer DOM update to avoid render warnings
        requestAnimationFrame(() => {
            if (objects.length === 0) {
                listEl.innerHTML = '<div class="loading">No objects found</div>';
                return;
            }

            listEl.innerHTML = objects.map(obj => {
                // Use the stored name from the database (what admin typed when creating)
                const displayName = obj.name || obj.type;
                return `
                <div class="object-item ${obj.collected ? 'collected' : ''}">
                    <h3>${displayName}</h3>
                    <div class="meta">
                        Type: ${obj.type}<br>
                        Location: ${obj.latitude.toFixed(6)}, ${obj.longitude.toFixed(6)}<br>
                        Radius: ${obj.radius}m<br>
                        ${obj.collected ? `Found by: ${obj.found_by || 'Unknown'}<br>Found at: ${new Date(obj.found_at).toLocaleString()}` : 'Status: Available'}
                    </div>
                    <div style="display: flex; gap: 8px; margin-top: 8px;">
                        ${obj.collected
                            ? `<button onclick="ObjectsManager.markUnfound('${obj.id}')" style="background: #ff9800; flex: 1;">Mark Unfound</button>`
                            : `<button onclick="ObjectsManager.markFound('${obj.id}')" style="background: #4caf50; flex: 1;">Mark Found</button>`
                        }
                        <button onclick="ObjectsManager.deleteObject('${obj.id}')" style="background: #d32f2f; flex: 1;">Delete</button>
                    </div>
                </div>
            `;
            }).join('');
        });
    },

    /**
     * Create new object
     */
    async createObject(formData) {
        const selectedLocation = MapManager.getSelectedLocation();
        if (!selectedLocation) {
            UI.showStatus('Please click on the map to select a location', 'error');
            return false;
        }

        // Generate UUID for object ID
        const id = 'obj-' + Date.now() + '-' + Math.random().toString(36).substr(2, 9);

        const objectData = {
            id: id,
            name: formData.name,
            type: formData.type,
            latitude: selectedLocation.lat,
            longitude: selectedLocation.lng,
            radius: parseFloat(formData.radius),
            created_by: 'admin-web-ui'
        };

        try {
            await ApiService.objects.create(objectData);
            UI.showStatus(`Object "${formData.name}" created successfully!`, 'success');

            // Reset form
            document.getElementById('objectForm').reset();
            document.getElementById('objectRadius').value = '5.0';
            document.getElementById('objectName').value = ''; // Clear name so it auto-fills on next type selection
            MapManager.clearSelectedLocation();

            // Reload objects and stats
            await this.loadObjects();
            await StatsManager.refreshStats();

            return true;
        } catch (error) {
            UI.showStatus('Error creating object: ' + error.message, 'error');
            return false;
        }
    },

    /**
     * Remove object marker from map immediately
     */
    removeObjectMarker(objectId) {
        if (this.markers[objectId]) {
            MapManager.getMap().removeLayer(this.markers[objectId]);
            delete this.markers[objectId];
            delete this.markerData[objectId];
            console.log(`🗑️ Removed marker for object: ${objectId}`);
        }

        // Reload objects list to update sidebar
        this.loadObjects().catch(err => {
            console.error('Error reloading objects after marker removal:', err);
        });

        // Refresh stats
        if (StatsManager && typeof StatsManager.refreshStats === 'function') {
            StatsManager.refreshStats();
        }
    },

    /**
     * Delete object
     */
    async deleteObject(objectId) {
        if (!confirm('Are you sure you want to delete this object? This action cannot be undone.')) {
            return;
        }

        try {
            // Remove marker immediately for instant feedback
            this.removeObjectMarker(objectId);

            await ApiService.objects.delete(objectId);
            UI.showStatus('Object deleted successfully', 'success');
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error deleting object: ' + error.message, 'error');
            // Reload objects to restore marker if deletion failed
            await this.loadObjects();
        }
    },

    /**
     * Mark object as found
     */
    async markFound(objectId) {
        try {
            await ApiService.objects.markFound(objectId);
            UI.showStatus('Object marked as found successfully', 'success');
            await this.loadObjects();
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error marking object as found: ' + error.message, 'error');
        }
    },

    /**
     * Mark object as unfound
     */
    async markUnfound(objectId) {
        try {
            await ApiService.objects.markUnfound(objectId);
            UI.showStatus('Object marked as unfound successfully', 'success');
            await this.loadObjects();
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error marking object as unfound: ' + error.message, 'error');
        }
    },

    // ============================================================================
    // Story Mode Elements (for Dead Men's Secrets mode)
    // ============================================================================

    /**
     * Load and display story mode elements on the map
     */
    async loadStoryElements() {
        try {
            const response = await ApiService.storyElements.getAll();
            const elements = response.story_elements || [];

            // Clear existing story markers
            this.clearStoryMarkers();

            if (elements.length === 0) {
                console.log('📖 No active story mode elements to display');
                return;
            }

            // Get current zoom level
            const currentZoom = MapManager.getMap() ? MapManager.getMap().getZoom() : 15;

            // Add markers for each story element
            elements.forEach(element => {
                this.addStoryMarker(element, currentZoom);
            });

            console.log(`📖 Loaded ${elements.length} story mode elements on map`);
        } catch (error) {
            console.error('Error loading story elements:', error);
        }
    },

    /**
     * Clear all story mode markers from the map
     */
    clearStoryMarkers() {
        Object.values(this.storyMarkers).forEach(marker => {
            if (MapManager.getMap()) {
                MapManager.getMap().removeLayer(marker);
            }
        });
        this.storyMarkers = {};
    },

    /**
     * Add a story mode marker to the map
     */
    addStoryMarker(element, zoom = 15) {
        const markerSize = this.calculateStoryMarkerSize(zoom, element.type);
        const icon = this.createStoryMarkerIcon(element, markerSize);

        const marker = L.marker([element.latitude, element.longitude], { icon })
            .addTo(MapManager.getMap())
            .bindPopup(`
                <strong>${element.name}</strong><br>
                <em>${element.description}</em><br>
                <span style="color: #666; font-size: 11px;">
                    Type: ${element.type}<br>
                    Location: ${element.latitude.toFixed(6)}, ${element.longitude.toFixed(6)}
                </span>
            `);

        this.storyMarkers[element.id] = marker;
    },

    /**
     * Calculate story marker size based on zoom and type
     */
    calculateStoryMarkerSize(zoom, type) {
        const baseSize = 28;
        const zoomFactor = Math.pow(1.15, zoom - 15);
        return Math.max(18, Math.min(40, baseSize * zoomFactor));
    },

    /**
     * Create story marker icon based on element type
     */
    createStoryMarkerIcon(element, size) {
        let bgColor, borderColor, iconEmoji;

        switch (element.type) {
            case 'skeleton':
                bgColor = '#ffd700';     // Gold
                borderColor = '#b8860b';
                iconEmoji = '💀';
                break;
            case 'corgi':
                bgColor = '#ff8c00';     // Dark orange
                borderColor = '#cc7000';
                iconEmoji = '🐕';
                break;
            case 'treasure':
                bgColor = '#ff0000';     // Red
                borderColor = '#cc0000';
                iconEmoji = '❌';
                break;
            case 'bandit':
                bgColor = '#8b0000';     // Dark red
                borderColor = '#5c0000';
                iconEmoji = '🏴‍☠️';
                break;
            default:
                bgColor = '#9932cc';     // Purple
                borderColor = '#7a28a3';
                iconEmoji = '❓';
        }

        const borderWidth = Math.max(2, Math.min(4, size / 8));
        const fontSize = size * 0.6;

        const iconHtml = `
            <div style="
                background: ${bgColor};
                width: ${size}px;
                height: ${size}px;
                border-radius: 50%;
                border: ${borderWidth}px solid ${borderColor};
                box-shadow: 0 0 ${size/2}px rgba(0, 0, 0, 0.3);
                display: flex;
                align-items: center;
                justify-content: center;
                font-size: ${fontSize}px;
            ">${iconEmoji}</div>
        `;

        return L.divIcon({
            className: 'story-marker',
            html: iconHtml,
            iconSize: [size, size],
            iconAnchor: [size / 2, size / 2]
        });
    },

    /**
     * Update story marker sizes based on zoom level
     */
    updateStoryMarkerSizes(zoom) {
        // This would need to store element data like markerData
        // For now, we can reload story elements on zoom change
        // which is less efficient but simpler
    },

    /**
     * Refresh a specific object marker (called when object is found/unfound)
     */
    refreshObjectMarker(objectId) {
        console.log('🔄 Refreshing object marker for:', objectId);
        
        // Check if we have this marker
        if (this.markers[objectId] && this.markerData[objectId]) {
            // Remove the current marker
            if (MapManager.getMap()) {
                MapManager.getMap().removeLayer(this.markers[objectId]);
            }
            
            // Get updated object data from server
            ApiService.objects.get(objectId).then(obj => {
                const currentZoom = MapManager.getMap() ? MapManager.getMap().getZoom() : 15;
                this.addObjectMarker(obj, currentZoom);
                console.log('✅ Object marker refreshed:', objectId);
            }).catch(error => {
                console.error('Error refreshing object marker:', error);
                // Fallback: reload all objects
                this.loadObjects();
            });
        } else {
            console.log('⚠️ Object marker not found for refresh:', objectId);
            // Fallback: reload all objects
            this.loadObjects();
        }
    },

    /**
     * Refresh the map based on current game mode
     * Called when game mode changes
     */
    async refreshForGameMode(gameMode) {
        if (gameMode === 'dead_mens_secrets') {
            // Story mode: Load story elements
            await this.loadStoryElements();
            console.log('📖 Story mode: Refreshed map with story elements');
        } else {
            // Open mode: Clear story markers
            this.clearStoryMarkers();
            console.log('🗺️ Open mode: Cleared story markers');
        }

        // Always reload regular objects
        await this.loadObjects();
    }
};

// Make ObjectsManager available globally
window.ObjectsManager = ObjectsManager;