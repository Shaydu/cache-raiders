/**
 * Map Manager - Handles Leaflet map initialization and management
 */
const MapManager = {
    map: null,
    selectedLocation: null,
    selectedMarker: null,

    /**
     * Initialize the map
     */
    async init() {
        const mapElement = document.getElementById('map');
        if (!mapElement) {
            console.error('Map element not found');
            return null;
        }

        // Ensure map container is visible and has dimensions
        if (mapElement.offsetWidth === 0 || mapElement.offsetHeight === 0) {
            console.warn('Map container has no dimensions, waiting...');
            await new Promise(resolve => setTimeout(resolve, 100));
            return this.init();
        }

        // Wait for next frame to ensure DOM is ready
        await new Promise(resolve => requestAnimationFrame(resolve));

        // Determine default center:
        // 1. Try last known user location from the server (persists across restarts)
        // 2. Fall back to Config.MAP_DEFAULT_CENTER if none available
        let defaultCenter = Config.MAP_DEFAULT_CENTER;
        let defaultZoom = Config.MAP_DEFAULT_ZOOM;

        try {
            const mapCenter = await ApiService.map.getDefaultCenter();
            if (mapCenter && typeof mapCenter.latitude === 'number' && typeof mapCenter.longitude === 'number') {
                defaultCenter = [mapCenter.latitude, mapCenter.longitude];
                console.log(`🗺️ Map initialized with last known user location: ${defaultCenter[0].toFixed(6)}, ${defaultCenter[1].toFixed(6)}`);
            } else {
                console.log('🗺️ No last known user location available, using default center from Config');
            }
        } catch (error) {
            console.warn('Could not get last known user location for map center, using default from Config:', error);
        }

        this.map = L.map('map').setView(defaultCenter, defaultZoom);

        const tileLayer = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
            attribution: '© OpenStreetMap contributors',
            maxZoom: Config.MAP_MAX_ZOOM,
            maxNativeZoom: Config.MAP_MAX_NATIVE_ZOOM
        });

        tileLayer.on('tileerror', function(error, tile) {
            console.warn('Tile load error at zoom level:', MapManager.map.getZoom(), error);
        });

        tileLayer.addTo(this.map);

        // Handle map clicks
        this.map.on('click', (e) => {
            const { lat, lng } = e.latlng;
            this.setSelectedLocation(lat, lng);
        });

        // Add center on top user control button
        this.addCenterOnTopUserControl();

        return this.map;
    },

    /**
     * Add control button to center on top user
     */
    addCenterOnTopUserControl() {
        const CenterOnTopUserControl = L.Control.extend({
            onAdd: function(map) {
                const container = L.DomUtil.create('div', 'center-on-top-user-control');
                container.innerHTML = `
                    <button class="center-on-top-user-btn" title="Center on top player">
                        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                            <circle cx="12" cy="12" r="8" fill="#2196F3" stroke="#fff" stroke-width="2"/>
                            <path d="M12 4 L12 8 M12 16 L12 20 M4 12 L8 12 M16 12 L20 12" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
                            <circle cx="12" cy="12" r="3" fill="#fff"/>
                        </svg>
                    </button>
                `;
                
                L.DomEvent.disableClickPropagation(container);
                L.DomEvent.on(container, 'click', function() {
                    UI.centerOnUserLocation();
                });
                
                return container;
            }
        });

        new CenterOnTopUserControl({ position: 'topright' }).addTo(this.map);
    },

    /**
     * Set selected location from map click
     */
    setSelectedLocation(lat, lng) {
        this.selectedLocation = { lat, lng };

        // Remove previous selection marker
        if (this.selectedMarker) {
            this.map.removeLayer(this.selectedMarker);
        }

        // Add new selection marker
        this.selectedMarker = L.marker([lat, lng], {
            icon: L.divIcon({
                className: 'selected-marker',
                html: '<div style="background: #ffd700; width: 20px; height: 20px; border-radius: 50%; border: 3px solid #1a1a1a; box-shadow: 0 0 10px rgba(255, 215, 0, 0.8);"></div>',
                iconSize: [20, 20]
            })
        }).addTo(this.map);

        const locationInfo = document.getElementById('locationInfo');
        if (locationInfo) {
            locationInfo.textContent = `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
        }
    },

    /**
     * Clear selected location
     */
    clearSelectedLocation() {
        this.selectedLocation = null;
        if (this.selectedMarker) {
            this.map.removeLayer(this.selectedMarker);
            this.selectedMarker = null;
        }
        const locationInfo = document.getElementById('locationInfo');
        if (locationInfo) {
            locationInfo.textContent = 'Click on map to set location';
        }
    },

    /**
     * Set map view
     */
    setView(center, zoom) {
        if (this.map) {
            this.map.setView(center, zoom);
        }
    },

    /**
     * Get map instance
     */
    getMap() {
        return this.map;
    },

    /**
     * Get selected location
     */
    getSelectedLocation() {
        return this.selectedLocation;
    }
};

// Make MapManager available globally
window.MapManager = MapManager;

