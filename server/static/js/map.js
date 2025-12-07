/**
 * Map Manager - Handles Apple MapKit JS map initialization and management
 */
const MapManager = {
    map: null,
    selectedLocation: null,
    selectedMarker: null,
    annotations: [], // Store MapKit annotations

    /**
     * Wait for MapKit library to be loaded
     */
    async waitForMapKit(maxWaitMs = 10000) {
        const startTime = Date.now();
        let checkCount = 0;

        while (typeof mapkit === 'undefined' && (Date.now() - startTime) < maxWaitMs) {
            checkCount++;
            if (checkCount % 10 === 0) {
                console.log(`⏳ Waiting for MapKit library to load... (${Math.round((Date.now() - startTime) / 1000)}s)`);
            }
            await new Promise(resolve => setTimeout(resolve, 100));
        }

        if (typeof mapkit === 'undefined') {
            const errorMsg = `❌ MapKit library not loaded after ${maxWaitMs/1000}s. Please check your network connection and ensure the MapKit script is included in the HTML before map.js.`;
            console.error(errorMsg);
            throw new Error(errorMsg);
        }

        console.log(`✅ MapKit library loaded successfully`);
        return mapkit;
    },

    /**
     * Initialize the map
     */
    async init() {
        // CRITICAL: Wait for MapKit to be loaded before using it
        try {
            await this.waitForMapKit();
        } catch (error) {
            console.error('❌ Failed to load MapKit library:', error);
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

        // Initialize MapKit with JWT token
        try {
            const tokenResponse = await fetch('/api/mapkit/token');
            if (!tokenResponse.ok) {
                throw new Error(`Failed to get MapKit token: ${tokenResponse.status}`);
            }
            const tokenData = await tokenResponse.json();

            mapkit.init({
                authorizationCallback: function(done) {
                    done(tokenData.token);
                }
            });

            console.log('✅ MapKit initialized with JWT token');
        } catch (error) {
            console.error('❌ Failed to initialize MapKit:', error);
            return null;
        }

        // Determine default center:
        // 1. Try last known user location from the server (persists across restarts)
        // 2. Fall back to Config.MAP_DEFAULT_CENTER if none available
        let defaultCenter = Config.MAP_DEFAULT_CENTER;

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

        // Create MapKit map
        this.map = new mapkit.Map('map');

        // Set initial region (MapKit uses CoordinateRegion)
        const center = new mapkit.Coordinate(defaultCenter[0], defaultCenter[1]);
        const span = new mapkit.CoordinateSpan(0.01, 0.01); // Roughly equivalent to zoom level
        this.map.region = new mapkit.CoordinateRegion(center, span);

        // Handle map clicks
        this.map.addEventListener('select', (event) => {
            if (event.annotation) {
                // Handle annotation selection
                return;
            }
            // Handle map click for placing objects
            const coordinate = event.coordinate;
            this.setSelectedLocation(coordinate.latitude, coordinate.longitude);
        });

        // Add center on top user control button
        this.addCenterOnTopUserControl();

        // Listen for zoom changes to update marker sizes
        this.map.addEventListener('region-change-end', () => {
            this.onZoomChange();
        });

        console.log('🗺️ Map initialized with Apple Maps');
        return this.map;
    },

    /**
     * Configure MapKit map settings
     */
    configureMap() {
        // MapKit automatically handles tiles - no manual tile layer needed
        // Configure map appearance and behavior
        this.map.showsMapTypeControl = false;
        this.map.showsZoomControl = true;
        this.map.showsUserLocation = false; // We'll handle user location manually
        this.map.showsUserLocationControl = false;

        console.log('🗺️ MapKit map configured');
    },

    /**
     * Handle zoom change - update all marker sizes
     */
    onZoomChange() {
        if (ObjectsManager && typeof ObjectsManager.updateMarkerSizes === 'function') {
            // MapKit uses different zoom scale, approximate based on region span
            const span = this.map.region.span;
            const approximateZoom = Math.round(14 - Math.log2(span.latitudeDelta * 111000 / 1000)); // Rough approximation
            ObjectsManager.updateMarkerSizes(approximateZoom);
        }
    },

    /**
     * Calculate marker size based on zoom level
     * @param {number} zoom - Current zoom level (approximated from MapKit region)
     * @param {boolean} isCollected - Whether marker is for collected item (X) or not (circle)
     * @returns {number} Marker size in pixels
     */
    calculateMarkerSize(zoom, isCollected) {
        // Base sizes at zoom level 15 (mid-range)
        const baseCircleSize = 18;
        const baseXSize = 20; // X's are slightly smaller than circles

        // Scale factor: smaller when zoomed out, larger when zoomed in
        // MapKit zoom approximation: adjust for different scale
        const zoomFactor = Math.pow(1.15, zoom - 15); // Exponential scaling

        if (isCollected) {
            // X markers: scale from 12px (zoom 10) to 30px (zoom 18)
            return Math.max(10, Math.min(28, baseXSize * zoomFactor * 0.85)); // 85% of circle size
        } else {
            // Circle markers: scale from 14px (zoom 10) to 35px (zoom 18)
            return Math.max(12, Math.min(32, baseCircleSize * zoomFactor));
        }
    },

    /**
     * Add control button to center on top user
     */
    addCenterOnTopUserControl() {
        // Create a custom control element
        const controlContainer = document.createElement('div');
        controlContainer.className = 'center-on-top-user-control';
        controlContainer.innerHTML = `
            <button class="center-on-top-user-btn" title="Center on top player">
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <circle cx="12" cy="12" r="8" fill="#2196F3" stroke="#fff" stroke-width="2"/>
                    <path d="M12 4 L12 8 M12 16 L12 20 M4 12 L8 12 M16 12 L20 12" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
                    <circle cx="12" cy="12" r="3" fill="#fff"/>
                </svg>
            </button>
        `;

        // Style the control to position it
        controlContainer.style.position = 'absolute';
        controlContainer.style.top = '10px';
        controlContainer.style.right = '10px';
        controlContainer.style.zIndex = '1000';

        // Add click handler
        const button = controlContainer.querySelector('.center-on-top-user-btn');
        button.addEventListener('click', () => {
            UI.centerOnUserLocation();
        });

        // Add to map container
        this.map.element.appendChild(controlContainer);
    },

    /**
     * Get the map instance (for backward compatibility)
     */
    getMap() {
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
