/**
 * LLM Settings Manager - Handles LLM provider and model settings
 * Separate component for better organization
 */
const LLMSettingsManager = {
    currentProvider: null,
    currentModel: null,

    /**
     * Initialize LLM settings manager
     */
    async init() {
        console.log('🚀 [LLM Settings] Starting initialization...');
        await this.loadLLMProvider();
        console.log('🚀 [LLM Settings] Provider loaded, setting up event listeners...');
        this.setupEventListeners();
        console.log('✅ [LLM Settings] Initialization complete');
    },

    /**
     * Setup event listeners for LLM controls
     */
    setupEventListeners() {
        console.log('🔧 [LLM Settings] setupEventListeners() called');
        const self = this;  // Capture context for use in event handlers

        // LLM provider dropdown
        const llmProviderSelect = document.getElementById('llmProvider');
        console.log('🔍 [LLM Settings] Provider dropdown element:', llmProviderSelect);
        if (llmProviderSelect) {
            // Mark that we've set up the listener to avoid duplicates
            if (llmProviderSelect.dataset.listenerAttached !== 'true') {
                console.log('✅ [LLM Settings] Setting up LLM provider change listener');
                llmProviderSelect.dataset.listenerAttached = 'true';

                llmProviderSelect.addEventListener('change', async function(e) {
                    const selectedProvider = e.target.value;
                    console.log('🔄 [LLM Settings] Provider dropdown changed to:', selectedProvider);

                    // Prevent multiple simultaneous calls
                    if (this.dataset.processing === 'true') {
                        console.log('⏸️ Already processing provider change, skipping...');
                        return;
                    }

                    this.dataset.processing = 'true';

                    try {
                        // CRITICAL: Immediately update model dropdown synchronously (before any async calls)
                        // This provides instant UI feedback
                        self.updateModelDropdownForProvider(selectedProvider);
                        console.log('✅ Model dropdown updated immediately for provider:', selectedProvider);

                        // Then sync with server (this will refine the dropdown with actual available models)
                        await self.onProviderChange();
                    } catch (err) {
                        console.error('❌ Error in provider change handler:', err);
                    } finally {
                        this.dataset.processing = 'false';
                    }
                });
            } else {
                console.log('⏭️ Provider listener already attached, skipping');
            }
        } else {
            console.warn('⚠️ LLM provider dropdown not found!');
        }

        // LLM model dropdown
        const llmModelSelect = document.getElementById('llmModel');
        if (llmModelSelect) {
            // Mark that we've set up the listener to avoid duplicates
            if (llmModelSelect.dataset.listenerAttached !== 'true') {
                console.log('✅ Setting up LLM model change listener');
                llmModelSelect.dataset.listenerAttached = 'true';

                llmModelSelect.addEventListener('change', function() {
                    console.log('🔄 LLM Model dropdown changed to:', this.value);
                    self.updateLLMProvider();
                });
            } else {
                console.log('⏭️ Model listener already attached, skipping');
            }
        }

        // Test LLM button
        const testLLMButton = document.getElementById('testLLMButton');
        if (testLLMButton) {
            // Mark that we've set up the listener to avoid duplicates
            if (testLLMButton.dataset.listenerAttached !== 'true') {
                console.log('✅ Setting up LLM test button listener');
                testLLMButton.dataset.listenerAttached = 'true';

                testLLMButton.addEventListener('click', function() {
                    self.testLLM();
                });
            } else {
                console.log('⏭️ Test button listener already attached, skipping');
            }
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
                this.currentProvider = data.provider;
                this.currentModel = data.model;
                
                // Update provider dropdown
                const providerDropdown = document.getElementById('llmProvider');
                if (providerDropdown) {
                    providerDropdown.value = data.provider;
                }
                
                // Update model dropdown based on provider
                await this.updateModelDropdown(data.provider, data.model, data.available_models, data.ollama_error);
                
                // Update info text
                this.updateStatusInfo(data);
                
                console.log(`🤖 LLM provider loaded: ${data.provider} (${data.model})`);
            } else {
                console.warn('Failed to load LLM provider');
            }
        } catch (error) {
            console.warn('Error loading LLM provider:', error);
        }
    },

    /**
     * Update status info display
     */
    updateStatusInfo(data) {
        const info = document.getElementById('llmProviderInfo');
        const statusDiv = document.getElementById('llmProviderStatus');
        
        if (!info) return;
        
        let statusText = `Current: ${data.provider} (${data.model})`;
        
        if (data.provider === 'openai') {
            statusText += data.api_key_configured ? ' ✅ API Key configured' : ' ⚠️ API Key missing';
            info.style.color = '';
            if (statusDiv) statusDiv.style.display = 'none';
        } else if (data.provider === 'ollama') {
            const baseUrl = data.ollama_base_url || 'http://localhost:11434';
            const location = data.ollama_location || (baseUrl.includes('ollama:') ? 'container' : 'local');
            statusText += ` - ${location === 'container' ? 'Container' : 'Local'} (${baseUrl})`;
            
            // Show error if models aren't available
            if (data.ollama_error || (data.available_models && data.available_models.length === 0)) {
                info.style.color = '#ff6b6b';
                if (statusDiv) {
                    statusDiv.style.display = 'block';
                    statusDiv.style.background = '#ff6b6b20';
                    statusDiv.style.border = '1px solid #ff6b6b';
                    statusDiv.style.color = '#ff6b6b';
                    if (data.ollama_error) {
                        statusDiv.innerHTML = `⚠️ <strong>Ollama Connection Error:</strong> ${data.ollama_error}<br><small>Click "Test LLM Connection" to diagnose</small>`;
                    } else {
                        statusDiv.innerHTML = `⚠️ <strong>No Ollama Models Found</strong><br><small>Install a model: ollama pull llama3:8b</small>`;
                    }
                }
            } else {
                statusText += ` - ${data.available_models.length} model(s) available`;
                info.style.color = '';
                if (statusDiv) statusDiv.style.display = 'none';
            }
        }
        
        info.textContent = statusText;
    },

    /**
     * Update model dropdown immediately when provider changes (before server call)
     * This provides instant UI feedback - MUST be synchronous!
     */
    updateModelDropdownForProvider(provider) {
        console.log(`🔄 [LLM Settings] updateModelDropdownForProvider called with provider: ${provider}`);
        const modelDropdown = document.getElementById('llmModel');
        console.log('🔍 [LLM Settings] Model dropdown element:', modelDropdown);
        if (!modelDropdown) {
            console.error('❌ [LLM Settings] Model dropdown not found!');
            return;
        }

        // Clear existing options
        modelDropdown.innerHTML = '';
        modelDropdown.disabled = false;
        console.log('🗑️ [LLM Settings] Cleared model dropdown');

        if (provider === 'openai') {
            // OpenAI models - known list
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
                modelDropdown.appendChild(option);
            });

            // Select first one by default
            if (modelDropdown.options.length > 0) {
                modelDropdown.selectedIndex = 0;
            }

            console.log(`✅ [LLM Settings] Populated OpenAI model dropdown with ${openaiModels.length} models`);
        } else if (provider === 'ollama') {
            // Show loading state for Ollama (will be updated by server response)
            // But keep dropdown enabled so user can switch back if needed
            const loadingOption = document.createElement('option');
            loadingOption.value = '';
            loadingOption.textContent = 'Loading Ollama models...';
            loadingOption.disabled = true;
            loadingOption.selected = true;
            modelDropdown.appendChild(loadingOption);
            modelDropdown.disabled = false;  // Changed: keep enabled so user can switch providers

            console.log('⏳ [LLM Settings] Showing loading state for Ollama models');
        } else {
            // Unknown provider
            const option = document.createElement('option');
            option.value = '';
            option.textContent = 'Unknown provider';
            option.disabled = true;
            modelDropdown.appendChild(option);
        }
    },

    /**
     * Update model dropdown based on provider (with server data)
     */
    async updateModelDropdown(provider, currentModel, availableModels = null, ollamaError = null) {
        const modelDropdown = document.getElementById('llmModel');
        if (!modelDropdown) return;
        
        // Clear existing options
        modelDropdown.innerHTML = '';
        
        if (provider === 'openai') {
            // OpenAI models - all are selectable
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
                option.disabled = false;
                if (model.value === currentModel) {
                    option.selected = true;
                }
                modelDropdown.appendChild(option);
            });
            
            modelDropdown.disabled = false;
            console.log(`✅ Populated OpenAI model dropdown with ${openaiModels.length} models`);
            
        } else if (provider === 'ollama') {
            // Ollama models - use available models from server or fetch them
            let models = availableModels || [];
            let error = ollamaError;
            
            if (models.length === 0 && !error) {
                // Try to fetch models if not provided
                try {
                    const response = await fetch(`${Config.API_BASE}/api/llm/provider`);
                    if (response.ok) {
                        const data = await response.json();
                        models = data.available_models || [];
                        error = data.ollama_error || null;
                        console.log(`📋 Fetched ${models.length} Ollama models in updateModelDropdown:`, models);
                    }
                } catch (fetchError) {
                    console.warn('Could not fetch Ollama models:', fetchError);
                    error = `Network error: ${fetchError.message}`;
                }
            }
            
            if (models.length > 0) {
                // Populate with available models - these are SELECTABLE
                models.forEach(modelName => {
                    const option = document.createElement('option');
                    option.value = modelName;
                    option.textContent = modelName;
                    option.disabled = false;
                    if (modelName === currentModel || (currentModel && modelName.includes(currentModel))) {
                        option.selected = true;
                    }
                    modelDropdown.appendChild(option);
                });
                
                // If no model was selected, select the first one
                if (!currentModel || !Array.from(modelDropdown.options).some(opt => opt.selected)) {
                    modelDropdown.selectedIndex = 0;
                }
                
                modelDropdown.disabled = false;
                console.log(`✅ Populated Ollama model dropdown with ${models.length} SELECTABLE models:`, models);
                
            } else {
                // No models available - show common Ollama models as selectable options
                // Even if Ollama is offline, allow user to select models they want to use when it comes online
                const commonOllamaModels = [
                    'granite4:350m',
                    'llama3:8b',
                    'llama3:70b',
                    'mistral:7b',
                    'phi3:mini'
                ];

                commonOllamaModels.forEach(modelName => {
                    const option = document.createElement('option');
                    option.value = modelName;
                    // Mark as not installed but keep selectable
                    option.textContent = `${modelName} ${error ? '(Ollama offline)' : '(not installed)'}`;
                    option.disabled = false;  // Changed: keep options selectable
                    if (modelName === currentModel) {
                        option.selected = true;
                    }
                    modelDropdown.appendChild(option);
                });

                // Add info message option at the top if there's an error
                if (error) {
                    const infoOption = document.createElement('option');
                    infoOption.value = '';
                    infoOption.textContent = `⚠️ Ollama offline - start it to see available models`;
                    infoOption.disabled = true;
                    // Insert at the beginning
                    modelDropdown.insertBefore(infoOption, modelDropdown.firstChild);
                    // If no current model, don't auto-select the error option
                    if (!currentModel && commonOllamaModels.length > 0) {
                        // Select first actual model instead
                        modelDropdown.selectedIndex = 1;  // Skip the info option
                    }
                }

                modelDropdown.disabled = false;
                console.warn('⚠️ No Ollama models available, showing selectable placeholder options');
            }
        } else {
            // Unknown provider
            console.warn(`Unknown provider: ${provider}`);
            const option = document.createElement('option');
            option.value = '';
            option.textContent = 'Unknown provider';
            option.disabled = true;
            modelDropdown.appendChild(option);
        }
    },

    /**
     * Handle provider change - update model dropdown and sync with server
     */
    async onProviderChange() {
        console.log('🔍 onProviderChange() called');
        const providerDropdown = document.getElementById('llmProvider');
        if (!providerDropdown) {
            console.error('❌ Provider dropdown not found!');
            return;
        }
        
        const provider = providerDropdown.value;
        if (!provider) {
            console.warn('⚠️ No provider selected');
            return;
        }
        
        console.log(`🔄 Provider changed to: ${provider}`);
        
        const modelDropdown = document.getElementById('llmModel');
        
        try {
            // Get current model selection (or use default)
            let modelToUse = null;
            if (modelDropdown && modelDropdown.value) {
                modelToUse = modelDropdown.value;
            } else {
                modelToUse = provider === 'ollama' ? 'granite4:350m' : 'gpt-4o-mini';
            }
            
            console.log(`📤 Sending POST request to set provider: ${provider}, model: ${modelToUse}`);
            const apiUrl = `${Config.API_BASE}/api/llm/provider`;
            
            let response;
            try {
                const controller = new AbortController();
                const timeoutId = setTimeout(() => controller.abort(), 30000);
                
                response = await fetch(apiUrl, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ 
                        provider: provider, 
                        model: modelToUse
                    }),
                    signal: controller.signal
                });
                
                clearTimeout(timeoutId);
                console.log(`📥 Response status: ${response.status} ${response.statusText}`);
            } catch (fetchError) {
                console.error('❌ Fetch error:', fetchError);
                
                if (modelDropdown) {
                    const errorOption = document.createElement('option');
                    errorOption.value = '';
                    errorOption.textContent = `⚠️ Network error: ${fetchError.message}`;
                    errorOption.disabled = true;
                    modelDropdown.innerHTML = '';
                    modelDropdown.appendChild(errorOption);
                    modelDropdown.disabled = false;
                }
                
                const statusDiv = document.getElementById('llmProviderStatus');
                if (statusDiv) {
                    statusDiv.style.display = 'block';
                    statusDiv.style.background = '#ff6b6b20';
                    statusDiv.style.border = '1px solid #ff6b6b';
                    statusDiv.style.color = '#ff6b6b';
                    statusDiv.innerHTML = `❌ <strong>Connection Error:</strong> ${fetchError.message}<br><small>Check if server is running at ${Config.API_BASE}</small>`;
                }
                return;
            }
            
            if (response.ok) {
                const data = await response.json();
                console.log(`📊 Server response:`, data);
                
                // Update model dropdown with server data
                await this.updateModelDropdown(
                    data.provider, 
                    data.model, 
                    data.available_models || [], 
                    data.ollama_error || null
                );
                
                if (modelDropdown) {
                    modelDropdown.disabled = false;
                }
                
                // Update status info
                this.updateStatusInfo(data);
                
                this.currentProvider = data.provider;
                this.currentModel = data.model;
                
                console.log(`✅ Provider changed and model dropdown updated: ${data.provider} (${data.model})`);
            } else {
                let errorData = {};
                try {
                    const text = await response.text();
                    try {
                        errorData = JSON.parse(text);
                    } catch {
                        errorData = { error: text };
                    }
                } catch (e) {
                    errorData = { error: 'Unknown error' };
                }
                
                console.error('Failed to update provider:', errorData);
                if (modelDropdown) {
                    modelDropdown.innerHTML = `<option value="">Error: ${response.status} - ${errorData.error || 'Unknown error'}</option>`;
                    modelDropdown.disabled = false;
                }
            }
        } catch (error) {
            console.error('❌ Exception in onProviderChange:', error);
            if (modelDropdown) {
                const errorOption = document.createElement('option');
                errorOption.value = '';
                errorOption.textContent = `⚠️ Error: ${error.message}`;
                errorOption.disabled = true;
                modelDropdown.innerHTML = '';
                modelDropdown.appendChild(errorOption);
                modelDropdown.disabled = false;
            }
            
            const statusDiv = document.getElementById('llmProviderStatus');
            if (statusDiv) {
                statusDiv.style.display = 'block';
                statusDiv.style.background = '#ff6b6b20';
                statusDiv.style.border = '1px solid #ff6b6b';
                statusDiv.style.color = '#ff6b6b';
                statusDiv.innerHTML = `❌ <strong>Error:</strong> ${error.message}`;
            }
        }
    },

    /**
     * Update LLM provider (called when model dropdown changes)
     */
    async updateLLMProvider() {
        const providerDropdown = document.getElementById('llmProvider');
        const modelDropdown = document.getElementById('llmModel');
        
        if (!providerDropdown) {
            console.error('Provider dropdown not found');
            return;
        }
        
        const provider = providerDropdown.value;
        if (!provider) {
            console.error('Invalid provider value');
            return;
        }
        
        // Get model from dropdown
        let model = null;
        if (modelDropdown && modelDropdown.value) {
            model = modelDropdown.value;
            console.log(`📋 Model selected from dropdown: ${model}`);
        } else {
            model = provider === 'ollama' ? 'llama3:8b' : 'gpt-4o-mini';
            console.warn(`⚠️ No model selected in dropdown, using default: ${model}`);
        }
        
        // Validate model matches provider
        if (provider === 'ollama' && model && model.startsWith('gpt-')) {
            console.warn('Invalid model for Ollama provider, using default');
            model = 'llama3:8b';
            if (modelDropdown) {
                modelDropdown.value = model;
            }
        } else if (provider === 'openai' && model && !model.startsWith('gpt-') && !model.startsWith('o1-')) {
            console.warn('Invalid model for OpenAI provider, using default');
            model = 'gpt-4o-mini';
            if (modelDropdown) {
                modelDropdown.value = model;
            }
        }
        
        console.log(`🔄 Updating LLM provider: ${provider}, model: ${model}`);
        
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
                
                // Refresh the model dropdown with latest data
                await this.updateModelDropdown(
                    data.provider, 
                    data.model, 
                    data.available_models, 
                    data.ollama_error
                );
                
                // Update status info
                this.updateStatusInfo(data);
                
                this.currentProvider = data.provider;
                this.currentModel = data.model;
                
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
            // Update provider/model based on current UI selections before testing
            const providerDropdown = document.getElementById('llmProvider');
            const modelDropdown = document.getElementById('llmModel');
            
            if (providerDropdown && modelDropdown) {
                const provider = providerDropdown.value;
                let model = modelDropdown.value;
                
                if (!model) {
                    model = provider === 'ollama' ? 'llama3:8b' : 'gpt-4o-mini';
                }
                
                console.log(`🧪 [Test] Updating provider to ${provider}, model to ${model} before testing...`);
                
                // Update provider/model on server first
                try {
                    const updateResponse = await fetch(`${Config.API_BASE}/api/llm/provider`, {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json'
                        },
                        body: JSON.stringify({ provider: provider, model: model })
                    });
                    
                    if (updateResponse.ok) {
                        const updateData = await updateResponse.json();
                        console.log(`✅ [Test] Provider updated to: ${updateData.provider}, model: ${updateData.model}`);
                    }
                } catch (updateError) {
                    console.warn(`⚠️ [Test] Error updating provider before test: ${updateError.message}`);
                }
            }
            
            // Get custom prompt from input field
            const promptInput = document.getElementById('llmTestPrompt');
            const customPrompt = promptInput ? promptInput.value.trim() : null;
            
            // Now test the connection with custom prompt
            const response = await fetch(`${Config.API_BASE}/api/llm/test`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ prompt: customPrompt || "Say 'Ahoy!' in pirate speak." })
            });
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

// Make available globally
window.LLMSettingsManager = LLMSettingsManager;
console.log('📦 [LLM Settings] llm_settings.js loaded, LLMSettingsManager registered to window');

// Debug function - test provider change manually
window.testProviderChange = function(provider) {
    console.log(`🧪 [DEBUG] Manually testing provider change to: ${provider}`);
    LLMSettingsManager.updateModelDropdownForProvider(provider);
};

// Debug - check if DOM elements exist when script loads
console.log('🔍 [LLM Settings] DOM check at script load:');
console.log('  - llmProvider element:', document.getElementById('llmProvider'));
console.log('  - llmModel element:', document.getElementById('llmModel'));
console.log('  - testLLMButton element:', document.getElementById('testLLMButton'));

