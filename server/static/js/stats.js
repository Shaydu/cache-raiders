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
            this.updateStatValue('totalFinds', stats.total_finds);

            // Update leaderboard
            this.updateLeaderboard(stats.top_finders || []);

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
    }
};

// Make StatsManager available globally
window.StatsManager = StatsManager;

