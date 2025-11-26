/**
 * Objects Manager - Handles object CRUD operations and display
 */
const ObjectsManager = {
    markers: {},

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

            // Add markers for each object
            objects.forEach(obj => {
                this.addObjectMarker(obj);
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
    addObjectMarker(obj) {
        const markerColor = obj.collected ? '#ff6b6b' : '#4caf50';
        const markerSize = obj.collected ? 14 : 18;
        const borderColor = obj.collected ? '#cc0000' : '#2d7a2d';

        // Use the stored name from the database (what admin typed when creating)
        const displayName = obj.name || obj.type;

        const icon = L.divIcon({
            className: 'object-marker',
            html: `<div style="background: ${markerColor}; width: ${markerSize}px; height: ${markerSize}px; border-radius: 50%; border: 3px solid ${borderColor}; box-shadow: 0 0 10px ${obj.collected ? 'rgba(255, 107, 107, 0.6)' : 'rgba(76, 175, 80, 0.6)'};"></div>`,
            iconSize: [markerSize, markerSize]
        });

        const marker = L.marker([obj.latitude, obj.longitude], { icon })
            .addTo(MapManager.getMap())
            .bindPopup(`
                <strong>${displayName}</strong><br>
                Type: ${obj.type}<br>
                Radius: ${obj.radius}m<br>
                ${obj.collected ? `<span style="color: #ff6b6b; font-weight: bold;">✓ Collected</span><br>Found by: ${obj.found_by || 'Unknown'}` : '<span style="color: #4caf50; font-weight: bold;">● Available</span>'}
            `);

        // Add click handler to open modal
        marker.on('click', () => {
            ModalManager.openObjectModal(obj.id);
        });

        this.markers[obj.id] = marker;
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
                    <button onclick="ObjectsManager.deleteObject('${obj.id}')" style="background: #d32f2f; margin-top: 8px;">Delete</button>
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
        if (!confirm('Are you sure you want to delete this object? This action cannot be undone.')) {
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
    }
};

// Make ObjectsManager available globally
window.ObjectsManager = ObjectsManager;

