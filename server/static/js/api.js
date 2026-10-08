/**
 * API Service - Handles all HTTP requests to the backend
 */
const ApiService = {
    /**
     * Generic fetch wrapper with error handling
     */
    async fetch(endpoint, options = {}) {
        const url = `${Config.API_BASE}${endpoint}`;
        const defaultOptions = {
            headers: {
                'Content-Type': 'application/json',
                ...options.headers
            },
            cache: 'no-cache',
            ...options
        };

        try {
            const response = await fetch(url, defaultOptions);
            if (!response.ok) {
                const error = await response.json().catch(() => ({ error: `HTTP error! status: ${response.status}` }));
                throw new Error(error.error || `HTTP error! status: ${response.status}`);
            }
            return await response.json();
        } catch (error) {
            console.error(`API Error [${endpoint}]:`, error);
            throw error;
        }
    },

    /**
     * Objects API
     */
    objects: {
        async getAll(includeFound = true) {
            return ApiService.fetch(`/api/objects?include_found=${includeFound}`);
        },

        async getById(id) {
            return ApiService.fetch(`/api/objects/${id}`);
        },

        async create(objectData) {
            return ApiService.fetch('/api/objects', {
                method: 'POST',
                body: JSON.stringify(objectData)
            });
        },

        async delete(id) {
            return ApiService.fetch(`/api/objects/${id}`, {
                method: 'DELETE'
            });
        },

        async markUnfound(id) {
            return ApiService.fetch(`/api/objects/${id}/found`, {
                method: 'DELETE'
            });
        },

        async markFound(id, foundBy = 'admin-web-ui') {
            return ApiService.fetch(`/api/objects/${id}/found`, {
                method: 'POST',
                body: JSON.stringify({ found_by: foundBy })
            });
        }
    },

    /**
     * Players API
     */
    players: {
        async getAll() {
            const cacheBuster = `?t=${Date.now()}`;
            return ApiService.fetch(`/api/players${cacheBuster}`);
        },

        async getById(deviceUuid) {
            return ApiService.fetch(`/api/players/${deviceUuid}`);
        },

        async updateName(deviceUuid, playerName) {
            return ApiService.fetch(`/api/players/${deviceUuid}`, {
                method: 'POST',
                body: JSON.stringify({ player_name: playerName })
            });
        },

        async delete(deviceUuid) {
            return ApiService.fetch(`/api/players/${deviceUuid}`, {
                method: 'DELETE'
            });
        },

        async kick(deviceUuid) {
            return ApiService.fetch(`/api/players/${deviceUuid}/kick`, {
                method: 'POST'
            });
        }
    },

    /**
     * Statistics API
     */
    stats: {
        async get() {
            const cacheBuster = `?t=${Date.now()}`;
            return ApiService.fetch(`/api/stats${cacheBuster}`);
        }
    },

    /**
     * User Locations API
     */
    userLocations: {
        async getAll() {
            return ApiService.fetch('/api/users/locations');
        }
    },

    /**
     * Map API
     */
    map: {
        async getDefaultCenter() {
            return ApiService.fetch('/api/map/default_center');
        }
    },

    /**
     * Story Mode Elements API (for admin map)
     */
    storyElements: {
        async getAll() {
            return ApiService.fetch('/api/admin/story-mode-elements');
        }
    },

    /**
     * Server Info API
     */
    serverInfo: {
        async get() {
            return ApiService.fetch('/api/server-info');
        }
    }
};

// Make ApiService available globally
window.ApiService = ApiService;

