/**
 * Game Mode Manager - Handles game mode settings
 * Separate component for better organization
 */
const GameModeManager = {
    currentGameMode: null,

    /**
     * Initialize game mode manager
     */
    async init() {
        await this.loadGameMode();
        this.setupEventListeners();
        this.setupWebSocketListener();
        
        // If we're starting in story mode, load story elements
        if (this.currentGameMode === 'dead_mens_secrets') {
            if (ObjectsManager && typeof ObjectsManager.loadStoryElements === 'function') {
                await ObjectsManager.loadStoryElements();
                console.log('📖 Loaded story mode elements on init');
            }
        }
        
        console.log('✅ Game mode manager initialized');
    },

    /**
     * Setup event listeners for game mode controls
     */
    setupEventListeners() {
        const gameModeSelect = document.getElementById('gameMode');
        if (gameModeSelect) {
            // Remove existing listeners by cloning
            const newSelect = gameModeSelect.cloneNode(true);
            gameModeSelect.parentNode.replaceChild(newSelect, gameModeSelect);
            
            newSelect.addEventListener('change', () => {
                this.updateGameMode();
            });
            console.log('✅ Game mode dropdown listener attached');
        } else {
            console.warn('⚠️ Game mode dropdown not found!');
        }
    },

    /**
     * Setup WebSocket listener for real-time game mode changes
     */
    setupWebSocketListener() {
        if (window.WebSocketManager && WebSocketManager.socket) {
            WebSocketManager.socket.on('game_mode_changed', (data) => {
                this.currentGameMode = data.game_mode;
                
                // Update dropdown
                const dropdown = document.getElementById('gameMode');
                if (dropdown) {
                    dropdown.value = data.game_mode;
                }
                
                console.log(`🎮 Game mode changed via WebSocket: ${data.game_mode}`);
                
                // Refresh map for new game mode (loads story elements if in story mode)
                if (ObjectsManager && typeof ObjectsManager.refreshForGameMode === 'function') {
                    ObjectsManager.refreshForGameMode(data.game_mode).then(() => {
                        console.log('🗺️ Map markers refreshed for new game mode (via WebSocket)');
                    });
                } else if (ObjectsManager && typeof ObjectsManager.loadObjects === 'function') {
                    ObjectsManager.loadObjects().then(() => {
                        console.log('🗺️ Map markers refreshed for new game mode (via WebSocket)');
                    });
                }
            });
            console.log('✅ Game mode WebSocket listener attached');
        }
    },

    /**
     * Load game mode from server
     */
    async loadGameMode() {
        try {
            const response = await fetch(`${Config.API_BASE}/api/settings/game-mode`);
            if (response.ok) {
                const data = await response.json();
                this.currentGameMode = data.game_mode;
                
                // Update dropdown to reflect current value
                const dropdown = document.getElementById('gameMode');
                if (dropdown) {
                    dropdown.value = data.game_mode;
                }
                
                console.log(`🎮 Game mode loaded: ${data.game_mode}`);
            } else {
                console.warn('Failed to load game mode, using default');
                this.currentGameMode = 'open'; // Default open mode
            }
        } catch (error) {
            console.warn('Error loading game mode:', error);
            this.currentGameMode = 'open'; // Default open mode
        }
    },

    /**
     * Update game mode
     */
    async updateGameMode() {
        const dropdown = document.getElementById('gameMode');
        if (!dropdown) return;
        
        const newGameMode = dropdown.value;
        if (!newGameMode) {
            console.error('Invalid game mode value');
            return;
        }
        
        try {
            const response = await fetch(`${Config.API_BASE}/api/settings/game-mode`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ game_mode: newGameMode })
            });
            
            if (response.ok) {
                const data = await response.json();
                this.currentGameMode = data.game_mode;
                
                // Show success message
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Game mode set to ${data.game_mode}`,
                        'success'
                    );
                }
                
                console.log(`✅ Game mode updated to: ${data.game_mode}`);
                
                // CRITICAL: Reload game mode from server to ensure UI is in sync
                await this.loadGameMode();
                
                // Refresh map for new game mode (loads story elements if in story mode)
                if (ObjectsManager && typeof ObjectsManager.refreshForGameMode === 'function') {
                    ObjectsManager.refreshForGameMode(data.game_mode).then(() => {
                        console.log('🗺️ Map markers refreshed for new game mode');
                    });
                } else if (ObjectsManager && typeof ObjectsManager.loadObjects === 'function') {
                    ObjectsManager.loadObjects().then(() => {
                        console.log('🗺️ Map markers refreshed for new game mode');
                    });
                }
            } else {
                const error = await response.json();
                console.error('Failed to update game mode:', error);
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Failed to update game mode: ${error.error || 'Unknown error'}`,
                        'error'
                    );
                }
            }
        } catch (error) {
            console.error('Error updating game mode:', error);
            if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                UIManager.showStatusMessage(
                    'Failed to update game mode: Network error',
                    'error'
                );
            }
        }
    }
};

// Make available globally
window.GameModeManager = GameModeManager;
console.log('📦 [Game Mode] game_mode.js loaded, GameModeManager registered to window');
