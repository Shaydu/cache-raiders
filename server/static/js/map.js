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

        this.map = L.map('map').setView(Config.MAP_DEFAULT_CENTER, Config.MAP_DEFAULT_ZOOM);

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

        return this.map;
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

