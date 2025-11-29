/**
 * Players Manager - Handles player management and display
 */
const PlayersManager = {
    /**
     * Load all players
     */
    async loadPlayers() {
        try {
            // Request connected clients list from server to sync connection status
            if (WebSocketManager.socket && WebSocketManager.socket.connected) {
                WebSocketManager.socket.emit('get_connected_clients');
            }
            
            const players = await ApiService.players.getAll();
            this.updatePlayersList(players);
        } catch (error) {
            console.error('Error loading players:', error);
            const listEl = document.getElementById('playersList');
            if (listEl) {
                listEl.innerHTML = `<div class="status error">Error loading players: ${error.message}</div>`;
            }
        }
    },

    /**
     * Update players list in sidebar
     */
    updatePlayersList(players) {
        const listEl = document.getElementById('playersList');
        if (!listEl) return;

        const showDisconnected = document.getElementById('showDisconnectedPlayers')?.checked ?? true;

        // Defer DOM update to avoid render warnings
        requestAnimationFrame(() => {
            if (players.length === 0) {
                listEl.innerHTML = '<div class="loading">No players found</div>';
                return;
            }

            // Filter players based on connection status if checkbox is unchecked
            let filteredPlayers = players;
            if (!showDisconnected) {
                filteredPlayers = players.filter(player => {
                    return WebSocketManager.isPlayerConnected(player.device_uuid);
                });
            }

            if (filteredPlayers.length === 0) {
                listEl.innerHTML = '<div class="loading">No connected players found</div>';
                return;
            }

            listEl.innerHTML = filteredPlayers.map(player => {
                const shortUuid = player.device_uuid.substring(0, 8) + '...';
                const updatedDate = new Date(player.updated_at).toLocaleString();
                const findCount = player.find_count || 0;
                const isConnected = WebSocketManager.isPlayerConnected(player.device_uuid);
                const connectionClass = isConnected ? 'connected' : 'disconnected';
                const connectionIndicator = `<span class="connection-indicator ${connectionClass}" title="${isConnected ? 'Connected via WebSocket' : 'Disconnected'}"></span>`;

                return `
                    <div class="object-item player-item ${connectionClass}">
                        <h3>${connectionIndicator}${player.player_name || 'Unnamed Player'}</h3>
                        <div class="meta">
                            Device ID: ${shortUuid}<br>
                            Full UUID: ${player.device_uuid}<br>
                            Finds: <span style="color: #4caf50; font-weight: bold;">${findCount}</span><br>
                            Status: <span style="color: ${isConnected ? '#4caf50' : '#999'}; font-weight: bold;">${isConnected ? '🟢 Connected' : '⚫ Disconnected'}</span><br>
                            Last Updated: ${updatedDate}
                        </div>
                        <div style="margin-top: 8px; display: flex; gap: 8px; align-items: center; flex-wrap: nowrap;">
                            <input type="text" id="player-name-${player.device_uuid}" 
                                   value="${player.player_name || ''}" 
                                   placeholder="Enter player name"
                                   onkeypress="if(event.key === 'Enter') PlayersManager.updatePlayerName('${player.device_uuid}')"
                                   style="flex: 1; padding: 6px; border: 1px solid #444; border-radius: 4px; background: #1a1a1a; color: #fff; font-size: 12px; min-width: 0;">
                            <div style="display: flex; gap: 6px; flex-shrink: 0;">
                                <button onclick="PlayersManager.updatePlayerName('${player.device_uuid}')" 
                                        style="background: #4caf50; color: #fff; border: none; border-radius: 4px; padding: 6px 12px; font-size: 12px; font-weight: bold; cursor: pointer; white-space: nowrap;">
                                    Update
                                </button>
                                <button onclick="PlayersManager.deletePlayer('${player.device_uuid}')" 
                                        style="background: #d32f2f; color: #fff; border: none; border-radius: 4px; padding: 6px 12px; font-size: 12px; font-weight: bold; cursor: pointer; transition: background 0.2s; white-space: nowrap;"
                                        onmouseover="this.style.background='#b71c1c'"
                                        onmouseout="this.style.background='#d32f2f'">
                                    Delete
                                </button>
                            </div>
                        </div>
                    </div>
                `;
            }).join('');
        });
    },

    /**
     * Refresh player list connection status without reloading from server
     */
    refreshPlayerListConnectionStatus() {
        const listEl = document.getElementById('playersList');
        if (!listEl) return;

        const items = listEl.querySelectorAll('.player-item');

        items.forEach(item => {
            const nameInput = item.querySelector('input[type="text"]');
            if (!nameInput) return;

            const deviceUuid = nameInput.id.replace('player-name-', '');
            const isConnected = WebSocketManager.isPlayerConnected(deviceUuid);
            const connectionClass = isConnected ? 'connected' : 'disconnected';

            // Update item class
            item.classList.remove('connected', 'disconnected');
            item.classList.add(connectionClass);

            // Update connection indicator
            const indicator = item.querySelector('.connection-indicator');
            if (indicator) {
                indicator.classList.remove('connected', 'disconnected');
                indicator.classList.add(connectionClass);
                indicator.title = isConnected ? 'Connected via WebSocket' : 'Disconnected';
            }

            // Update status text
            const meta = item.querySelector('.meta');
            if (meta) {
                const statusMatch = meta.innerHTML.match(/Status:.*<br>/);
                if (statusMatch) {
                    meta.innerHTML = meta.innerHTML.replace(
                        statusMatch[0],
                        `Status: <span style="color: ${isConnected ? '#4caf50' : '#999'}; font-weight: bold;">${isConnected ? '🟢 Connected' : '⚫ Disconnected'}</span><br>`
                    );
                }
            }
        });
    },

    /**
     * Update player name
     */
    async updatePlayerName(deviceUuid) {
        const nameInput = document.getElementById(`player-name-${deviceUuid}`);
        if (!nameInput) return;

        const newName = nameInput.value.trim();

        if (!newName) {
            UI.showStatus('Player name cannot be empty', 'error');
            return;
        }

        try {
            await ApiService.players.updateName(deviceUuid, newName);
            UI.showStatus(`Player name updated to "${newName}"`, 'success');
            // Reload players and stats to reflect changes
            await this.loadPlayers();
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error updating player name: ' + error.message, 'error');
        }
    },

    /**
     * Delete player
     */
    async deletePlayer(deviceUuid) {
        if (!confirm('Are you sure you want to delete this player? This will also delete all their finds and make those objects available again. This action cannot be undone.')) {
            return;
        }

        try {
            const result = await ApiService.players.delete(deviceUuid);
            UI.showStatus(result.message || 'Player deleted successfully', 'success');
            // Reload players, objects, and stats to reflect changes
            await this.loadPlayers();
            await ObjectsManager.loadObjects();
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error deleting player: ' + error.message, 'error');
        }
    }
};

// Make PlayersManager available globally
window.PlayersManager = PlayersManager;

