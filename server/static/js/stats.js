/**
 * Statistics Manager - Handles statistics and leaderboard display
 */
const StatsManager = {
    /**
     * Refresh statistics and leaderboard
     */
    async refreshStats() {
        try {
            const stats = await ApiService.stats.get();

            // Update stat values
            this.updateStatValue('totalObjects', stats.total_objects);
            this.updateStatValue('foundObjects', stats.found_objects);
            this.updateStatValue('unfoundObjects', stats.unfound_objects);
            
            // Calculate and display average finds per player
            // Average = total finds / number of players who have finds
            let avgFinds = '0.0';
            if (stats.total_finds && stats.top_finders && stats.top_finders.length > 0) {
                const playersWithFinds = stats.top_finders.length;
                const average = stats.total_finds / playersWithFinds;
                avgFinds = average.toFixed(1);
            }
            this.updateStatValue('avgFinds', avgFinds);

            // Update leaderboard
            this.updateLeaderboard(stats.top_finders || []);

            // Update type counts
            this.updateTypeCounts(stats.counts_by_type || {});

            console.log('Stats refreshed:', stats);
        } catch (error) {
            console.error('Error loading stats:', error);
            UI.showStatus('Error refreshing stats: ' + error.message, 'error');
        }
    },

    /**
     * Update a single stat value
     */
    updateStatValue(elementId, value) {
        const element = document.getElementById(elementId);
        if (element) {
            element.textContent = value;
        }
    },

    /**
     * Update leaderboard display
     */
    updateLeaderboard(topFinders) {
        const leaderboardEl = document.getElementById('leaderboard');
        if (!leaderboardEl) return;

        // Defer DOM update to avoid render warnings
        requestAnimationFrame(() => {
            // Show loading state briefly
            leaderboardEl.innerHTML = '<div class="loading">Refreshing...</div>';

            // Small delay to ensure UI updates
            setTimeout(() => {
                requestAnimationFrame(() => {
                    if (topFinders.length === 0) {
                        leaderboardEl.innerHTML = '<div class="loading">No finds yet. Be the first!</div>';
                        return;
                    }

                    leaderboardEl.innerHTML = topFinders.map((finder, index) => {
                        const rank = index + 1;
                        const rankClass = rank === 1 ? 'rank-1' : rank === 2 ? 'rank-2' : rank === 3 ? 'rank-3' : '';
                        const badgeClass = rank === 1 ? 'rank-1' : rank === 2 ? 'rank-2' : rank === 3 ? 'rank-3' : 'rank-other';
                        const rankIcon = rank === 1 ? '👑' : rank === 2 ? '🥈' : rank === 3 ? '🥉' : rank;

                        return `
                            <div class="leaderboard-item ${rankClass}">
                                <div class="rank-badge ${badgeClass}">${rankIcon}</div>
                                <div class="leaderboard-user">${finder.user || 'Unknown'}</div>
                                <div class="leaderboard-count">
                                    <span>✓</span>
                                    <span>${finder.count}</span>
                                </div>
                            </div>
                        `;
                    }).join('');

                    console.log('Leaderboard updated with', topFinders.length, 'players');
                });
            }, 100);
        });
    },

    /**
     * Update type counts display
     */
    updateTypeCounts(countsByType) {
        const typeCountsEl = document.getElementById('typeCountsList');
        if (!typeCountsEl) return;

        // Defer DOM update to avoid render warnings
        requestAnimationFrame(() => {
            if (!countsByType || Object.keys(countsByType).length === 0) {
                typeCountsEl.innerHTML = '<div class="loading">No objects found</div>';
                return;
            }

            // Sort types alphabetically
            const sortedTypes = Object.keys(countsByType).sort();
            
            typeCountsEl.innerHTML = sortedTypes.map(type => {
                const count = countsByType[type];
                return `
                    <div style="display: flex; justify-content: space-between; align-items: center; padding: 6px 8px; background: #1a1a1a; border-radius: 4px;">
                        <span style="color: #ccc; font-size: 13px;">${type}</span>
                        <span style="color: #ffd700; font-weight: 600; font-size: 13px;">${count}</span>
                    </div>
                `;
            }).join('');

            console.log('Type counts updated:', countsByType);
        });
    }
};

// Make StatsManager available globally
window.StatsManager = StatsManager;

