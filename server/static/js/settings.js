/**
 * Settings Manager - Handles admin panel settings
 */
const SettingsManager = {
    locationUpdateInterval: null,
    locationUpdateIntervalTimer: null,
    gameMode: null,

    /**
     * Initialize settings manager
     */
    async init() {
        await this.loadLocationUpdateInterval();
        await this.loadGameMode();
        await this.loadLLMProvider();
        this.setupWebSocketListener();
    },

    /**
     * Load location update interval from server
     */
    async loadLocationUpdateInterval() {
        try {
            const response = await fetch(`${Config.API_BASE}/api/settings/location-update-interval`);
            if (response.ok) {
                const data = await response.json();
                this.locationUpdateInterval = data.interval_ms;
                Config.USER_LOCATION_UPDATE_INTERVAL = data.interval_ms;
                
                // Update dropdown to reflect current value
                const dropdown = document.getElementById('locationUpdateInterval');
                if (dropdown) {
                    dropdown.value = data.interval_ms.toString();
                }
                
                // Restart location polling with new interval
                this.restartLocationPolling();
                
                console.log(`📍 Location update interval loaded: ${data.interval_ms}ms (${data.interval_seconds}s)`);
            } else {
                console.warn('Failed to load location update interval, using default');
                this.locationUpdateInterval = 1000; // Default 1 second
            }
        } catch (error) {
            console.warn('Error loading location update interval:', error);
            this.locationUpdateInterval = 1000; // Default 1 second
        }
    },

    /**
     * Update location update interval
     */
    async updateLocationInterval() {
        const dropdown = document.getElementById('locationUpdateInterval');
        if (!dropdown) return;
        
        const intervalMs = parseInt(dropdown.value);
        if (isNaN(intervalMs)) {
            console.error('Invalid interval value');
            return;
        }
        
        try {
            const response = await fetch(`${Config.API_BASE}/api/settings/location-update-interval`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ interval_ms: intervalMs })
            });
            
            if (response.ok) {
                const data = await response.json();
                this.locationUpdateInterval = data.interval_ms;
                Config.USER_LOCATION_UPDATE_INTERVAL = data.interval_ms;
                
                // Restart location polling with new interval
                this.restartLocationPolling();
                
                // Show success message
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Location update interval set to ${data.interval_seconds}s`,
                        'success'
                    );
                }
                
                console.log(`✅ Location update interval updated to ${data.interval_ms}ms (${data.interval_seconds}s)`);
            } else {
                const error = await response.json();
                console.error('Failed to update location update interval:', error);
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Failed to update interval: ${error.error || 'Unknown error'}`,
                        'error'
                    );
                }
            }
        } catch (error) {
            console.error('Error updating location update interval:', error);
            if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                UIManager.showStatusMessage(
                    'Failed to update interval: Network error',
                    'error'
                );
            }
        }
    },

    /**
     * Restart location polling with new interval
     */
    restartLocationPolling() {
        // Clear existing interval if it exists
        if (this.locationUpdateIntervalTimer) {
            clearInterval(this.locationUpdateIntervalTimer);
            this.locationUpdateIntervalTimer = null;
        }
        
        // Find and clear the existing interval in main.js
        // We'll need to store a reference to it in main.js
        if (window.App && window.App.locationUpdateIntervalId) {
            clearInterval(window.App.locationUpdateIntervalId);
            window.App.locationUpdateIntervalId = null;
        }
        
        // Start new interval
        if (UserLocationsManager && typeof UserLocationsManager.loadUserLocations === 'function') {
            window.App.locationUpdateIntervalId = setInterval(() => {
                UserLocationsManager.loadUserLocations();
            }, Config.USER_LOCATION_UPDATE_INTERVAL);
            
            console.log(`🔄 Restarted location polling with interval: ${Config.USER_LOCATION_UPDATE_INTERVAL}ms (${Config.USER_LOCATION_UPDATE_INTERVAL/1000}s)`);
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
                this.gameMode = data.game_mode;
                
                // Update dropdown to reflect current value
                const dropdown = document.getElementById('gameMode');
                if (dropdown) {
                    dropdown.value = data.game_mode;
                }
                
                console.log(`🎮 Game mode loaded: ${data.game_mode}`);
            } else {
                console.warn('Failed to load game mode, using default');
                this.gameMode = 'open'; // Default open mode
            }
        } catch (error) {
            console.warn('Error loading game mode:', error);
            this.gameMode = 'open'; // Default open mode
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
                this.gameMode = data.game_mode;
                
                // Show success message
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Game mode set to ${data.game_mode}`,
                        'success'
                    );
                }
                
                console.log(`✅ Game mode updated to: ${data.game_mode}`);
                
                // Reload objects to update map display (filter based on new game mode)
                // This will clear existing markers and re-add only the ones that match the new game mode
                if (ObjectsManager && typeof ObjectsManager.loadObjects === 'function') {
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
    },

    /**
     * Setup WebSocket listener for interval changes
     */
    setupWebSocketListener() {
        if (window.WebSocketManager && WebSocketManager.socket) {
            WebSocketManager.socket.on('location_update_interval_changed', (data) => {
                this.locationUpdateInterval = data.interval_ms;
                Config.USER_LOCATION_UPDATE_INTERVAL = data.interval_ms;
                
                // Update dropdown
                const dropdown = document.getElementById('locationUpdateInterval');
                if (dropdown) {
                    dropdown.value = data.interval_ms.toString();
                }
                
                // Restart polling
                this.restartLocationPolling();
                
                console.log(`📍 Location update interval changed via WebSocket: ${data.interval_ms}ms (${data.interval_seconds}s)`);
            });

            WebSocketManager.socket.on('game_mode_changed', (data) => {
                this.gameMode = data.game_mode;
                
                // Update dropdown
                const dropdown = document.getElementById('gameMode');
                if (dropdown) {
                    dropdown.value = data.game_mode;
                }
                
                console.log(`🎮 Game mode changed via WebSocket: ${data.game_mode}`);
                
                // Reload objects to update map display (filter based on new game mode)
                // This will clear existing markers and re-add only the ones that match the new game mode
                if (ObjectsManager && typeof ObjectsManager.loadObjects === 'function') {
                    ObjectsManager.loadObjects().then(() => {
                        console.log('🗺️ Map markers refreshed for new game mode (via WebSocket)');
                    });
                }
            });
        }
    },

    /**
     * Load LLM provider from server
     */
    async loadLLMProvider() {
        try {
            const response = await fetch(`${Config.API_BASE}/api/llm/provider`);
            if (response.ok) {
                const data = await response.json();
                
                // Update provider dropdown
                const providerDropdown = document.getElementById('llmProvider');
                if (providerDropdown) {
                    providerDropdown.value = data.provider;
                }
                
                // Update model dropdown based on provider
                await this.updateModelDropdown(data.provider, data.model, data.available_models);
                
                // Update info text
                const info = document.getElementById('llmProviderInfo');
                if (info) {
                    let statusText = `Current: ${data.provider} (${data.model})`;
                    if (data.provider === 'openai') {
                        statusText += data.api_key_configured ? ' ✅ API Key configured' : ' ⚠️ API Key missing';
                    } else if (data.provider === 'ollama') {
                        statusText += ` - Base URL: ${data.ollama_base_url || 'http://localhost:11434'}`;
                    }
                    info.textContent = statusText;
                }
                
                console.log(`🤖 LLM provider loaded: ${data.provider} (${data.model})`);
            } else {
                console.warn('Failed to load LLM provider');
            }
        } catch (error) {
            console.warn('Error loading LLM provider:', error);
        }
    },

    /**
     * Update model dropdown based on provider
     */
    async updateModelDropdown(provider, currentModel, availableModels = null) {
        const modelDropdown = document.getElementById('llmModel');
        if (!modelDropdown) return;
        
        // Clear existing options
        modelDropdown.innerHTML = '';
        
        if (provider === 'openai') {
            // OpenAI models
            const openaiModels = [
                { value: 'gpt-4o-mini', label: 'gpt-4o-mini (Fast & Cheap)' },
                { value: 'gpt-4o', label: 'gpt-4o (Best Quality)' },
                { value: 'gpt-4-turbo', label: 'gpt-4-turbo (High Quality)' },
                { value: 'gpt-3.5-turbo', label: 'gpt-3.5-turbo (Legacy)' }
            ];
            
            openaiModels.forEach(model => {
                const option = document.createElement('option');
                option.value = model.value;
                option.textContent = model.label;
                if (model.value === currentModel) {
                    option.selected = true;
                }
                modelDropdown.appendChild(option);
            });
        } else if (provider === 'ollama') {
            // Ollama models - use available models from server or fetch them
            let models = availableModels || [];
            
            if (models.length === 0) {
                // Try to fetch models if not provided
                try {
                    const response = await fetch(`${Config.API_BASE}/api/llm/provider`);
                    if (response.ok) {
                        const data = await response.json();
                        models = data.available_models || [];
                    }
                } catch (error) {
                    console.warn('Could not fetch Ollama models:', error);
                }
            }
            
            if (models.length > 0) {
                models.forEach(modelName => {
                    const option = document.createElement('option');
                    option.value = modelName;
                    option.textContent = modelName;
                    if (modelName === currentModel || modelName.includes(currentModel)) {
                        option.selected = true;
                    }
                    modelDropdown.appendChild(option);
                });
            } else {
                // No models available
                const option = document.createElement('option');
                option.value = 'llama3:8b';
                option.textContent = 'llama3:8b (No models found - install with: ollama pull llama3:8b)';
                option.selected = currentModel === 'llama3:8b';
                modelDropdown.appendChild(option);
            }
        }
    },

    /**
     * Handle provider change - update model dropdown
     */
    async onProviderChange() {
        const providerDropdown = document.getElementById('llmProvider');
        if (!providerDropdown) return;
        
        const provider = providerDropdown.value;
        
        // Determine default model for the provider
        const defaultModel = provider === 'ollama' ? 'llama3:8b' : 'gpt-4o-mini';
        
        // First, update the provider on the server with the default model
        // This ensures the server knows which provider we're using and uses a valid model
        try {
            const response = await fetch(`${Config.API_BASE}/api/llm/provider`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ provider: provider, model: defaultModel })
            });
            
            if (response.ok) {
                const data = await response.json();
                
                // Now fetch available models (server will return models for the new provider)
                let availableModels = null;
                if (provider === 'ollama') {
                    availableModels = data.available_models || [];
                    // If not in response, fetch separately
                    if (!availableModels || availableModels.length === 0) {
                        try {
                            const providerResponse = await fetch(`${Config.API_BASE}/api/llm/provider`);
                            if (providerResponse.ok) {
                                const providerData = await providerResponse.json();
                                availableModels = providerData.available_models || [];
                            }
                        } catch (error) {
                            console.warn('Could not fetch Ollama models:', error);
                        }
                    }
                }
                
                // Update model dropdown with fetched models, using the model from server response
                await this.updateModelDropdown(provider, data.model || defaultModel, availableModels);
                
                // Update info text
                const info = document.getElementById('llmProviderInfo');
                if (info) {
                    let statusText = `Current: ${data.provider} (${data.model})`;
                    if (data.provider === 'openai') {
                        statusText += data.api_key_configured ? ' ✅ API Key configured' : ' ⚠️ API Key missing';
                    } else if (data.provider === 'ollama') {
                        statusText += ` - Base URL: ${data.ollama_base_url || 'http://localhost:11434'}`;
                    }
                    info.textContent = statusText;
                }
            }
        } catch (error) {
            console.error('Error updating provider:', error);
            // Fallback: just update dropdown without fetching models
            await this.updateModelDropdown(provider, defaultModel);
        }
    },

    /**
     * Update LLM provider
     */
    async updateLLMProvider() {
        const providerDropdown = document.getElementById('llmProvider');
        const modelDropdown = document.getElementById('llmModel');
        
        if (!providerDropdown) return;
        
        const provider = providerDropdown.value;
        if (!provider) {
            console.error('Invalid provider value');
            return;
        }
        
        // Get model from dropdown, or use default based on provider
        let model = null;
        if (modelDropdown && modelDropdown.value) {
            model = modelDropdown.value;
        } else {
            // Fallback to defaults based on provider
            model = provider === 'ollama' ? 'llama3:8b' : 'gpt-4o-mini';
        }
        
        // Validate model matches provider (prevent sending OpenAI model to Ollama)
        if (provider === 'ollama' && model && model.startsWith('gpt-')) {
            console.warn('Invalid model for Ollama provider, using default');
            model = 'llama3:8b';
            // Update dropdown to reflect correct model
            if (modelDropdown) {
                modelDropdown.value = model;
            }
        } else if (provider === 'openai' && model && !model.startsWith('gpt-')) {
            console.warn('Invalid model for OpenAI provider, using default');
            model = 'gpt-4o-mini';
            // Update dropdown to reflect correct model
            if (modelDropdown) {
                modelDropdown.value = model;
            }
        }
        
        try {
            const response = await fetch(`${Config.API_BASE}/api/llm/provider`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ provider: provider, model: model })
            });
            
            if (response.ok) {
                const data = await response.json();
                
                // Update info text
                const info = document.getElementById('llmProviderInfo');
                if (info) {
                    let statusText = `Current: ${data.provider} (${data.model})`;
                    if (data.provider === 'openai') {
                        statusText += ' ✅';
                    } else if (data.provider === 'ollama') {
                        statusText += ` - Base URL: ${data.ollama_base_url || 'http://localhost:11434'}`;
                    }
                    info.textContent = statusText;
                }
                
                // Show success message
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `LLM provider switched to ${data.provider}`,
                        'success'
                    );
                }
                
                console.log(`✅ LLM provider updated to: ${data.provider} (${data.model})`);
            } else {
                const error = await response.json();
                console.error('Failed to update LLM provider:', error);
                if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                    UIManager.showStatusMessage(
                        `Failed to update LLM provider: ${error.error || 'Unknown error'}`,
                        'error'
                    );
                }
            }
        } catch (error) {
            console.error('Error updating LLM provider:', error);
            if (window.UIManager && typeof UIManager.showStatusMessage === 'function') {
                UIManager.showStatusMessage(
                    'Failed to update LLM provider: Network error',
                    'error'
                );
            }
        }
    },

    /**
     * Test LLM connection
     */
    async testLLM() {
        const statusDiv = document.getElementById('llmProviderStatus');
        if (statusDiv) {
            statusDiv.style.display = 'block';
            statusDiv.style.background = '#333';
            statusDiv.style.color = '#ccc';
            statusDiv.textContent = 'Testing LLM connection...';
        }
        
        try {
            const response = await fetch(`${Config.API_BASE}/api/llm/test`);
            const data = await response.json();
            
            if (statusDiv) {
                if (data.status === 'success') {
                    statusDiv.style.background = '#1a4d1a';
                    statusDiv.style.color = '#90ee90';
                    statusDiv.textContent = `✅ Success! Response: "${data.response}" (${data.provider}/${data.model})`;
                } else {
                    statusDiv.style.background = '#4d1a1a';
                    statusDiv.style.color = '#ff6b6b';
                    statusDiv.textContent = `❌ Error: ${data.error || 'Unknown error'}`;
                }
            }
            
            console.log('🧪 LLM test result:', data);
        } catch (error) {
            if (statusDiv) {
                statusDiv.style.background = '#4d1a1a';
                statusDiv.style.color = '#ff6b6b';
                statusDiv.textContent = `❌ Network error: ${error.message}`;
            }
            console.error('Error testing LLM:', error);
        }
    }
};

// Make SettingsManager available globally
window.SettingsManager = SettingsManager;

