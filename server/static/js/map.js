/**
 * Map Manager - Handles Leaflet map initialization and management
 */
const MapManager = {
    map: null,
    selectedLocation: null,
    selectedMarker: null,
    currentTileLayer: null,
    currentMapStyle: 'standard', // 'standard' or 'pirate'

    /**
     * Get saved map style preference or default to 'standard'
     */
    getMapStylePreference() {
        const saved = localStorage.getItem('mapStyle');
        return saved || 'standard';
    },

    /**
     * Save map style preference
     */
    saveMapStylePreference(style) {
        localStorage.setItem('mapStyle', style);
    },

    /**
     * Wait for Leaflet library to be loaded
     */
    async waitForLeaflet(maxWaitMs = 10000) {
        const startTime = Date.now();
        let checkCount = 0;
        
        while (typeof L === 'undefined' && (Date.now() - startTime) < maxWaitMs) {
            checkCount++;
            if (checkCount % 10 === 0) {
                console.log(`⏳ Waiting for Leaflet library to load... (${Math.round((Date.now() - startTime) / 1000)}s)`);
            }
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        
        if (typeof L === 'undefined') {
            const errorMsg = `❌ Leaflet library (L) not loaded after ${maxWaitMs/1000}s. Please check your network connection and ensure the Leaflet script is included in the HTML before map.js.`;
            console.error(errorMsg);
            throw new Error(errorMsg);
        }
        
        console.log(`✅ Leaflet library loaded successfully`);
        return L;
    },

    /**
     * Initialize the map
     */
    async init() {
        // CRITICAL: Wait for Leaflet to be loaded before using it
        try {
            await this.waitForLeaflet();
        } catch (error) {
            console.error('❌ Failed to load Leaflet library:', error);
            return null;
        }

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

        // Load saved map style preference
        this.currentMapStyle = this.getMapStylePreference();
        
        // Update radio button to match saved preference
        const standardRadio = document.getElementById('mapStyleStandard');
        const pirateRadio = document.getElementById('mapStylePirate');
        if (standardRadio && pirateRadio) {
            if (this.currentMapStyle === 'pirate') {
                pirateRadio.checked = true;
            } else {
                standardRadio.checked = true;
            }
        }

        // Initialize with the saved style
        this.setMapStyle(this.currentMapStyle, false); // false = don't save (already saved)

        // Handle map clicks
        this.map.on('click', (e) => {
            const { lat, lng } = e.latlng;
            this.setSelectedLocation(lat, lng);
        });

        // Add center on top user control button
        this.addCenterOnTopUserControl();

        // Listen for zoom changes to update marker sizes
        this.map.on('zoomend', () => {
            this.onZoomChange();
        });

        // Also listen for zoom start to update during zoom (smoother)
        this.map.on('zoom', () => {
            this.onZoomChange();
        });

        return this.map;
    },

    /**
     * Handle zoom change - update all marker sizes
     */
    onZoomChange() {
        if (ObjectsManager && typeof ObjectsManager.updateMarkerSizes === 'function') {
            ObjectsManager.updateMarkerSizes(this.map.getZoom());
        }
    },

    /**
     * Calculate marker size based on zoom level
     * @param {number} zoom - Current zoom level
     * @param {boolean} isCollected - Whether marker is for collected item (X) or not (circle)
     * @returns {number} Marker size in pixels
     */
    calculateMarkerSize(zoom, isCollected) {
        // Base sizes at zoom level 15 (mid-range)
        const baseCircleSize = 18;
        const baseXSize = 20; // X's are slightly smaller than circles
        
        // Scale factor: smaller when zoomed out, larger when zoomed in
        // Zoom levels typically range from 0 (world view) to 18+ (street level)
        // At zoom 10: ~50% of base size
        // At zoom 15: 100% of base size
        // At zoom 18: ~150% of base size
        const zoomFactor = Math.pow(1.15, zoom - 15); // Exponential scaling
        
        if (isCollected) {
            // X markers: scale from 12px (zoom 10) to 30px (zoom 18)
            // But make them a bit smaller than circles
            return Math.max(10, Math.min(28, baseXSize * zoomFactor * 0.85)); // 85% of circle size
        } else {
            // Circle markers: scale from 14px (zoom 10) to 35px (zoom 18)
            return Math.max(12, Math.min(32, baseCircleSize * zoomFactor));
        }
    },

    /**
     * Set map style (standard or pirate)
     */
    setMapStyle(style, savePreference = true) {
        if (!this.map) {
            console.warn('Map not initialized yet');
            return;
        }
        
        if (typeof L === 'undefined') {
            console.error('Leaflet library (L) not loaded');
            return;
        }

        // Remove existing tile layer
        if (this.currentTileLayer) {
            this.map.removeLayer(this.currentTileLayer);
        }

        // Remove/add CSS classes for styling
        const mapElement = document.getElementById('map');
        if (style === 'pirate') {
            mapElement.classList.add('pirate-map-style');
        } else {
            mapElement.classList.remove('pirate-map-style');
        }

        // Create new tile layer based on style
        let tileLayer;
        if (style === 'pirate') {
            // Pirate map style - Google Maps with custom styled map
            const pirateMapStyles = [
                {
                    "featureType": "all",
                    "elementType": "labels.text.fill",
                    "stylers": [
                        { "color": "#5d4e37" },  // dark brown text for readability
                        { "weight": "normal" }
                    ]
                },
                {
                    "featureType": "all",
                    "elementType": "labels.text.stroke",
                    "stylers": [
                        { "color": "#e8d8b0" },  // parchment-colored stroke
                        { "weight": 2 }
                    ]
                },
                {
                    "featureType": "landscape",
                    "elementType": "geometry",
                    "stylers": [
                        { "color": "#e8d8b0" }   // parchment land
                    ]
                },
                {
                    "featureType": "water",
                    "elementType": "geometry",
                    "stylers": [
                        { "color": "#c3b48c" },  // muted brown water
                        { "saturation": -30 }
                    ]
                },
                {
                    "featureType": "water",
                    "elementType": "labels.text.fill",
                    "stylers": [
                        { "color": "#8b7355" }  // darker brown for water labels
                    ]
                },
                {
                    "featureType": "road",
                    "elementType": "geometry.stroke",
                    "stylers": [
                        { "color": "#7d6541" },  // rough "inked" lines
                        { "weight": 1.5 }
                    ]
                },
                {
                    "featureType": "road",
                    "elementType": "geometry.fill",
                    "stylers": [
                        { "color": "#d8c7a1" }
                    ]
                },
                {
                    "featureType": "road",
                    "elementType": "labels.text.fill",
                    "stylers": [
                        { "color": "#5d4e37" }  // dark brown for road labels
                    ]
                },
                {
                    "featureType": "poi",
                    "elementType": "geometry",
                    "stylers": [
                        { "color": "#d4c4a5" }  // slightly different color for POIs
                    ]
                },
                {
                    "featureType": "poi",
                    "elementType": "labels.text.fill",
                    "stylers": [
                        { "color": "#5d4e37" }  // dark brown for POI labels
                    ]
                },
                {
                    "featureType": "administrative",
                    "elementType": "geometry.stroke",
                    "stylers": [
                        { "color": "#7d6541" },  // brown stroke for boundaries
                        { "weight": 1 }
                    ]
                },
                {
                    "featureType": "administrative",
                    "elementType": "labels.text.fill",
                    "stylers": [
                        { "color": "#5d4e37" }  // dark brown for admin labels
                    ]
                }
            ];

            // Use Google Maps styled map with Leaflet.GoogleMutant
            tileLayer = L.gridLayer.googleMutant({
                type: 'roadmap',
                styles: pirateMapStyles,
                maxZoom: Config.MAP_MAX_ZOOM
            });
        } else {
            // Standard style - OpenStreetMap
            tileLayer = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                attribution: '© OpenStreetMap contributors',
                maxZoom: Config.MAP_MAX_ZOOM,
                maxNativeZoom: Config.MAP_MAX_NATIVE_ZOOM
            });
        }

        tileLayer.on('tileerror', function(error, tile) {
            console.warn('Tile load error at zoom level:', MapManager.map.getZoom(), error);
        });

        tileLayer.addTo(this.map);
        this.currentTileLayer = tileLayer;
        this.currentMapStyle = style;

        // Save preference
        if (savePreference) {
            this.saveMapStylePreference(style);
        }

        console.log(`🗺️ Map style changed to: ${style}`);
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

