/**
 * QR Code Manager - Handles QR code generation and server URL management
 */
const QRCodeManager = {
    serverURL: Config.API_BASE,

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
        } catch (error) {
            console.warn('⚠️ Failed to fetch server info, using default');
            this.serverURL = Config.API_BASE;
            const urlInput = document.getElementById('serverURL');
            if (urlInput) {
                urlInput.value = this.serverURL;
            }
        }
        return this.serverURL;
    },

    /**
     * Handle QR code image load error
     */
    handleQRCodeError() {
        const container = document.getElementById('qrcodeContainer');
        const urlInput = document.getElementById('serverURL');
        const currentServerURL = urlInput ? urlInput.value : this.serverURL || 'Unknown';
        
        if (container) {
            container.innerHTML = `
                <div style="padding: 20px; background: #2a2a2a; border-radius: 8px; color: #ff6b6b; text-align: center;">
                    <strong>⚠️ Failed to load QR code</strong><br>
                    <span style="font-size: 12px; display: block; margin-top: 10px;">Please manually enter the server URL in your iOS app:</span>
                    <code style="display: block; margin-top: 10px; padding: 8px; background: #1a1a1a; border-radius: 4px; word-break: break-all; color: #fff;">${currentServerURL}</code>
                    <button onclick="location.reload()" style="margin-top: 10px; padding: 8px 16px; background: #ffd700; color: #1a1a1a; border: none; border-radius: 4px; cursor: pointer; font-weight: bold;">
                        🔄 Refresh Page
                    </button>
                </div>
            `;
        }
    },

    /**
     * Initialize QR code (now uses server-side generation)
     */
    async initQRCode() {
        // Fetch server info to get the network IP
        const currentServerURL = await this.fetchServerInfo();
        
        const urlInput = document.getElementById('serverURL');
        const container = document.getElementById('qrcodeContainer');
        const qrImg = document.getElementById('qrcode');
        
        if (!urlInput || !container) {
            console.error('QR code elements not found');
            return;
        }
        
        // Update the input field with the network IP URL
        urlInput.value = currentServerURL;
        
        // Update QR code image with cache busting
        if (qrImg) {
            qrImg.src = `/api/qrcode?t=${Date.now()}`;
            qrImg.onerror = () => this.handleQRCodeError();
            console.log('✅ QR code image URL updated');
        } else {
            // Create img element if it doesn't exist
            const img = document.createElement('img');
            img.id = 'qrcode';
            img.src = `/api/qrcode?t=${Date.now()}`;
            img.alt = 'Server QR Code';
            img.style.cssText = 'background: white; padding: 10px; border-radius: 8px; display: inline-block; max-width: 100%;';
            img.onerror = () => this.handleQRCodeError();
            container.innerHTML = '';
            container.appendChild(img);
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

