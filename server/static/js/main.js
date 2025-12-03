/**
 * Main Application - Initialization and orchestration
 */
const App = {
    /**
     * Initialize the application
     */
    async init() {
        // Wait for DOM to be fully ready and next render cycle
        await new Promise(resolve => {
            if (document.readyState === 'complete') {
                requestAnimationFrame(() => {
                    requestAnimationFrame(resolve);
                });
            } else {
                window.addEventListener('load', () => {
                    requestAnimationFrame(() => {
                        requestAnimationFrame(resolve);
                    });
                });
            }
        });

        // Set up event handlers first (these don't modify DOM)
        this.setupFormHandler();
        this.setupModalHandlers();

        // Defer all DOM modifications to next tick
        setTimeout(async () => {
            // Initialize map (modifies DOM)
            await MapManager.init();

            // Wait a bit more before loading data to ensure map is ready
            setTimeout(async () => {
                await ObjectsManager.loadObjects();
                await StatsManager.refreshStats();
                
                // Initialize settings manager (loads location update interval from server)
                await SettingsManager.init();
                
                // Load user locations FIRST so connection status is accurate when players list loads
                await UserLocationsManager.loadUserLocations();
                
                // Then load players list (which will check connection status based on locations)
                await PlayersManager.loadPlayers();
                
                // Set up periodic location updates (interval is set by SettingsManager)
                App.locationUpdateIntervalId = setInterval(() => {
                    UserLocationsManager.loadUserLocations();
                }, Config.USER_LOCATION_UPDATE_INTERVAL);

                // Connect to WebSocket for real-time updates
                WebSocketManager.connect();
                WebSocketManager.startConnectionMonitor();
                
                // Initialize diagnostics manager after WebSocket connection
                // Wait a moment for WebSocket to connect
                setTimeout(() => {
                    if (DiagnosticsManager) {
                        DiagnosticsManager.init();
                        // Request connected clients list
                        if (WebSocketManager.socket && WebSocketManager.socket.connected) {
                            WebSocketManager.socket.emit('get_connected_clients');
                        }
                    }
                }, 2000);

                // Auto-refresh every 30 seconds
                setInterval(() => {
                    ObjectsManager.loadObjects();
                    StatsManager.refreshStats();
                    PlayersManager.loadPlayers();
                }, Config.AUTO_REFRESH_INTERVAL);
            }, 100);

            // Initialize QR code (modifies DOM)
            this.initQRCode();
        }, 0);
    },

    /**
     * Set up form handler for object creation
     */
    setupFormHandler() {
        const form = document.getElementById('objectForm');
        if (!form) return;

        // Auto-populate name when type is selected
        const typeSelect = document.getElementById('objectType');
        const nameInput = document.getElementById('objectName');
        
        if (typeSelect && nameInput) {
            typeSelect.addEventListener('change', (e) => {
                const selectedType = e.target.value;
                if (selectedType && (!nameInput.value || nameInput.value.trim() === '')) {
                    // Only auto-fill if name field is empty
                    nameInput.value = Config.generateDefaultName(selectedType);
                }
            });
        }

        form.addEventListener('submit', async (e) => {
            e.preventDefault();

            const formData = {
                name: document.getElementById('objectName').value,
                type: document.getElementById('objectType').value,
                radius: document.getElementById('objectRadius').value
            };

            await ObjectsManager.createObject(formData);
        });
    },

    /**
     * Set up modal handlers
     */
    setupModalHandlers() {
        const modal = document.getElementById('objectModal');
        if (!modal) return;

        // Close modal when clicking outside
        modal.addEventListener('click', (e) => {
            if (e.target === modal) {
                ModalManager.closeModal();
            }
        });

        // Close modal with Escape key
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                ModalManager.closeModal();
            }
        });
    },

    /**
     * Initialize QR code (server-side generation)
     */
    async initQRCode() {
        // Fetch server info and initialize QR code
        await QRCodeManager.initQRCode();
    }
};

// Initialize app when DOM is ready
const initializeApp = async () => {
    // Wait for DOM to be interactive before doing anything
    if (document.readyState === 'loading') {
        await new Promise(resolve => {
            document.addEventListener('DOMContentLoaded', resolve, { once: true });
        });
    }
    
    // Fetch server info (lightweight, doesn't modify DOM)
    QRCodeManager.fetchServerInfo().catch(err => {
        console.warn('Failed to fetch server info:', err);
    });
    
    // Initialize the full app (will handle its own timing)
    App.init().catch(err => {
        console.error('Failed to initialize app:', err);
    });
};

// Start initialization
initializeApp();

// Make App available globally
window.App = App;

/**
 * Legend Manager - Handles map legend functionality
 */
const LegendManager = {
    isExpanded: false,

    /**
     * Initialize legend
     */
    init() {
        console.log('🗺️ Legend initialized');
        this.setupEventListeners();
        // Start minimized by default
        this.collapseLegend();
    },

    /**
     * Setup event listeners
     */
    setupEventListeners() {
        const legend = document.getElementById('mapLegend');
        if (legend) {
            // Click anywhere on minimized legend to expand
            legend.addEventListener('click', (e) => {
                if (!this.isExpanded && !e.target.closest('.legend-toggle')) {
                    this.expandLegend();
                }
            });

            // Prevent clicks inside expanded legend from collapsing
            legend.addEventListener('click', (e) => {
                if (this.isExpanded) {
                    e.stopPropagation();
                }
            });
        }

        // Click anywhere outside expanded legend to collapse
        document.addEventListener('click', (e) => {
            const legend = document.getElementById('mapLegend');
            if (this.isExpanded && legend && !legend.contains(e.target)) {
                this.collapseLegend();
            }
        });
    },

    /**
     * Toggle legend visibility
     */
    toggleLegend() {
        if (this.isExpanded) {
            this.collapseLegend();
        } else {
            this.expandLegend();
        }
    },

    /**
     * Expand legend
     */
    expandLegend() {
        const legend = document.getElementById('mapLegend');
        if (!legend) return;

        this.isExpanded = true;
        legend.classList.add('expanded');
        
        // Update toggle button text
        const toggleBtn = legend.querySelector('.legend-toggle');
        if (toggleBtn) {
            toggleBtn.textContent = '−';
        }
    },

    /**
     * Collapse legend
     */
    collapseLegend() {
        const legend = document.getElementById('mapLegend');
        if (!legend) return;

        this.isExpanded = false;
        legend.classList.remove('expanded');
        
        // Update toggle button text
        const toggleBtn = legend.querySelector('.legend-toggle');
        if (toggleBtn) {
            toggleBtn.textContent = '+';
        }
    },

    /**
     * Update legend based on current map state
     */
    updateLegend() {
        // This can be expanded to dynamically update legend items
        // based on what's currently visible on the map
        console.log('🗺️ Legend updated');
    }
};

// Make LegendManager available globally
window.LegendManager = LegendManager;

// Initialize legend when DOM is loaded
document.addEventListener('DOMContentLoaded', function() {
    LegendManager.init();
});

