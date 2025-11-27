/**
 * Objects Manager - Handles object CRUD operations and display
 */
const ObjectsManager = {
    markers: {},
    markerData: {}, // Store marker data for resizing

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

            // Get current zoom level
            const currentZoom = MapManager.getMap() ? MapManager.getMap().getZoom() : 15;

            // Add markers for each object
            objects.forEach(obj => {
                this.addObjectMarker(obj, currentZoom);
            });

            // Update objects list in sidebar
            this.updateObjectsList(objects);
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
        const icon = this.createMarkerIcon(obj.collected, markerSize);

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
    createMarkerIcon(isCollected, size) {
        let iconHtml;
        const anchorOffset = size / 2;
        
        if (isCollected) {
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
            const newIcon = this.createMarkerIcon(markerInfo.collected, newSize);
            
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
     * Delete object
     */
    async deleteObject(objectId) {
        // First confirmation
        if (!confirm('Are you sure you want to delete this object? This action cannot be undone.')) {
            return;
        }

        // Second confirmation
        if (!confirm('This is your final warning. Are you absolutely sure you want to delete this object?')) {
            return;
        }

        try {
            await ApiService.objects.delete(objectId);
            UI.showStatus('Object deleted successfully', 'success');
            await this.loadObjects();
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error deleting object: ' + error.message, 'error');
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
    }
};

// Make ObjectsManager available globally
window.ObjectsManager = ObjectsManager;

