/**
 * Configuration constants
 */
const Config = {
    API_BASE: window.location.origin,
    MAP_DEFAULT_CENTER: [40.0758, -105.3008],
    MAP_DEFAULT_ZOOM: 15,
    MAP_MAX_ZOOM: 22,
    MAP_MAX_NATIVE_ZOOM: 19,
    USER_LOCATION_UPDATE_INTERVAL: 5000, // 5 seconds
    CONNECTION_CHECK_INTERVAL: 5000, // 5 seconds
    DISCONNECTED_THRESHOLD: 60000, // 60 seconds
    AUTO_REFRESH_INTERVAL: 30000, // 30 seconds
    STATUS_MESSAGE_DURATION: 5000, // 5 seconds
    OBJECT_TYPES: [
        'Chalice',
        'Temple Relic',
        'Treasure Chest',
        'Loot Chest',
        'Loot Cart',
        'Mysterious Sphere',
        'Mysterious Cube'
    ],
    
    /**
     * Name variants for each object type (matching Swift LootBoxFactory)
     */
    OBJECT_NAME_VARIANTS: {
        'Chalice': ['Sacred Chalice', 'Ancient Chalice', 'Golden Chalice'],
        'Treasure Chest': ['Treasure Chest', 'Ancient Chest', 'Locked Chest'],
        'Loot Chest': ['Loot Chest', 'Treasure Chest', 'Ancient Chest'],
        'Loot Cart': ['Loot Cart', 'Golden Cart', 'Treasure Cart'],
        'Temple Relic': ['Temple Relic', 'Sacred Relic', 'Temple Treasure'],
        'Mysterious Sphere': ['Mysterious Sphere', 'Ancient Orb', 'Glowing Sphere'],
        'Mysterious Cube': ['Mysterious Cube']
    },
    
    /**
     * Generate a random default name for an object type
     */
    generateDefaultName(objectType) {
        const variants = this.OBJECT_NAME_VARIANTS[objectType];
        if (!variants || variants.length === 0) {
            return objectType; // Fallback to type name
        }
        // Pick a random variant
        return variants[Math.floor(Math.random() * variants.length)];
    }
};

// Make Config available globally
window.Config = Config;

