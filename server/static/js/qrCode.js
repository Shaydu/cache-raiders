/**
 * QR Code Manager - Handles QR code generation and server URL management
 */
const QRCodeManager = {
    serverURL: Config.API_BASE,
    isRefreshing: false, // Flag to prevent race conditions during refresh

    /**
     * Update the server address display element
     */
    updateAddressDisplay() {
        // Wait for DOM to be ready
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', () => this.updateAddressDisplay());
            return;
        }
        
        const addressDisplay = document.getElementById('serverAddressText');
        if (addressDisplay && this.serverURL) {
            // Extract IP:port from URL (remove http:// prefix)
            const ipPort = this.serverURL.replace(/^https?:\/\//, '');
            addressDisplay.textContent = ipPort;
            console.log('✅ Updated server address display:', ipPort);
        }
    },

    /**
     * Fetch server network IP and update URL
     */
    async fetchServerInfo() {
        try {
            const info = await ApiService.serverInfo.get();
            const port = info.port || 5001;
            this.serverURL = `http://${info.local_ip}:${port}`;
            console.log('✅ Server info:', info);
            console.log('📱 Using network IP for QR code:', this.serverURL);
            console.log('   Local IP:', info.local_ip);
            console.log('   Port:', port);
            
            // Immediately update the URL input field
            const urlInput = document.getElementById('serverURL');
            if (urlInput) {
                urlInput.value = this.serverURL;
                console.log('✅ Updated URL field to:', this.serverURL);
            }
            
            // Update the address display (with callback to ensure DOM is ready)
            this.updateAddressDisplay();
        } catch (error) {
            console.warn('⚠️ Failed to fetch server info, using default');
            this.serverURL = Config.API_BASE;
            const urlInput = document.getElementById('serverURL');
            if (urlInput) {
                urlInput.value = this.serverURL;
            }
            
            // Update the address display even on error
            this.updateAddressDisplay();
        }
        return this.serverURL;
    },

    /**
     * Handle QR code image load error
     */
    handleQRCodeError() {
        // Don't show error if we're in the middle of refreshing
        if (this.isRefreshing) {
            console.log('⏳ QR code error during refresh, ignoring...');
            return;
        }
        
        const container = document.getElementById('qrcodeContainer');
        const urlInput = document.getElementById('serverURL');
        const currentServerURL = urlInput ? urlInput.value : this.serverURL || 'Unknown';
        
        if (container) {
            container.innerHTML = `
                <div style="padding: 20px; background: #2a2a2a; border-radius: 8px; color: #ff6b6b; text-align: center;">
                    <strong>⚠️ Failed to load QR code</strong><br>
                    <span style="font-size: 12px; display: block; margin-top: 10px;">Please manually enter the server URL in your iOS app:</span>
                    <code style="display: block; margin-top: 10px; padding: 8px; background: #1a1a1a; border-radius: 4px; word-break: break-all; color: #fff;">${currentServerURL}</code>
                    <button onclick="QRCodeManager.initQRCode()" style="margin-top: 10px; padding: 8px 16px; background: #ffd700; color: #1a1a1a; border: none; border-radius: 4px; cursor: pointer; font-weight: bold;">
                        🔄 Retry
                    </button>
                </div>
            `;
        }
    },

    /**
     * Initialize QR code (now uses server-side generation)
     */
    async initQRCode() {
        // Set refreshing flag to prevent error handler from interfering
        this.isRefreshing = true;
        
        try {
            // Fetch server info to get the network IP
            const currentServerURL = await this.fetchServerInfo();
            
            const urlInput = document.getElementById('serverURL');
            const container = document.getElementById('qrcodeContainer');
            
            if (!urlInput || !container) {
                console.error('QR code elements not found');
                return;
            }
            
            // Update the input field with the network IP URL
            urlInput.value = currentServerURL;
            
            // Update the address display (uses callback to ensure DOM is ready)
            this.updateAddressDisplay();
            
            // Check if container was replaced by error handler - restore structure if needed
            const qrImg = document.getElementById('qrcode');
            if (!qrImg || !container.querySelector('img#qrcode')) {
                // Restore the container structure (was replaced by error handler)
                container.innerHTML = `
                    <div style="position: relative; display: inline-block;">
                        <img id="qrcode" src="/api/qrcode?t=${Date.now()}" alt="Server QR Code" style="background: white; padding: 10px; border-radius: 8px; display: inline-block; max-width: 100%;" onerror="QRCodeManager.handleQRCodeError()">
                        <button onclick="QRCodeManager.initQRCode()" style="position: absolute; bottom: 8px; right: 8px; background: rgba(0, 0, 0, 0.7); border: 1px solid #666; color: #fff; padding: 4px 6px; border-radius: 4px; cursor: pointer; font-size: 10px; display: flex; align-items: center; justify-content: center; width: 24px; height: 24px; backdrop-filter: blur(4px);" title="Regenerate QR Code">
                            <span style="font-size: 12px;">🔄</span>
                        </button>
                    </div>
                `;
                console.log('✅ QR code container structure restored');
                
                // Wait for image to load before clearing refresh flag
                const newImg = document.getElementById('qrcode');
                if (newImg) {
                    newImg.onload = () => {
                        this.isRefreshing = false;
                        console.log('✅ QR code loaded successfully');
                    };
                    // Also set a timeout to clear the flag even if load event doesn't fire
                    setTimeout(() => {
                        if (this.isRefreshing) {
                            this.isRefreshing = false;
                            console.log('⏳ QR code refresh flag cleared (timeout)');
                        }
                    }, 2000);
                } else {
                    this.isRefreshing = false;
                }
            } else {
                // Image exists, just update it with cache busting
                // Temporarily remove error handler to prevent false errors when clearing src
                qrImg.onerror = null;
                qrImg.src = '';
                // Use setTimeout to ensure the browser processes the empty src before setting new one
                setTimeout(() => {
                    const timestamp = Date.now();
                    // Set error handler before setting new src
                    qrImg.onerror = () => this.handleQRCodeError();
                    qrImg.src = `/api/qrcode?t=${timestamp}`;
                    
                    // Wait for image to load before clearing refresh flag
                    qrImg.onload = () => {
                        this.isRefreshing = false;
                        console.log('✅ QR code image regenerated and loaded');
                    };
                    // Also set a timeout to clear the flag even if load event doesn't fire
                    setTimeout(() => {
                        if (this.isRefreshing) {
                            this.isRefreshing = false;
                            console.log('⏳ QR code refresh flag cleared (timeout)');
                        }
                    }, 2000);
                }, 10);
            }
        } catch (error) {
            console.error('Error initializing QR code:', error);
            this.isRefreshing = false;
        }
    },

    /**
     * Copy server URL to clipboard
     */
    async copyServerURL() {
        await this.fetchServerInfo();
        const urlInput = document.getElementById('serverURL');
        if (urlInput) {
            urlInput.value = this.serverURL;
            await UI.copyToClipboard(this.serverURL);
        }
    },

    /**
     * Get current server URL
     */
    getServerURL() {
        return this.serverURL;
    }
};

// Make QRCodeManager available globally
window.QRCodeManager = QRCodeManager;

