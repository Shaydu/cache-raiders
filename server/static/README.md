# Admin UI - Modular Structure

This directory contains the refactored admin UI, following Single Responsibility Principle (SRP) and Don't Repeat Yourself (DRY) principles.

## Directory Structure

```
static/
├── css/
│   └── styles.css          # All CSS styles
└── js/
    ├── config.js           # Configuration constants
    ├── api.js              # API service layer (all HTTP requests)
    ├── ui.js               # UI utilities (status messages, etc.)
    ├── map.js              # Map initialization and management
    ├── websocket.js        # WebSocket connection handling
    ├── userLocations.js    # User location tracking
    ├── stats.js            # Statistics and leaderboard
    ├── players.js          # Player management
    ├── qrCode.js           # QR code generation
    ├── modal.js            # Modal management
    ├── objects.js          # Object CRUD operations
    └── main.js             # Main initialization and orchestration
```

## Module Responsibilities

### config.js
- Configuration constants (API base URL, intervals, map settings, etc.)
- Single source of truth for all configuration values

### api.js
- Centralized API service layer
- Handles all HTTP requests to the backend
- Provides consistent error handling
- Organized by resource (objects, players, stats, etc.)

### ui.js
- UI utility functions
- Status message display
- Browser location centering
- Clipboard operations

### map.js
- Leaflet map initialization
- Map view management
- Location selection handling

### websocket.js
- WebSocket connection management
- Real-time event handling
- Player connection status tracking

### userLocations.js
- User location marker management
- Location updates from API and WebSocket
- Player name caching

### stats.js
- Statistics display
- Leaderboard rendering
- Stat value updates

### players.js
- Player list management
- Player name updates
- Connection status display

### qrCode.js
- QR code generation
- Server URL management
- Network IP fetching

### modal.js
- Modal display and management
- Object details rendering
- Modal event handling

### objects.js
- Object CRUD operations
- Object marker management
- Object list display

### main.js
- Application initialization
- Module orchestration
- Event handler setup
- Auto-refresh scheduling

## Benefits of This Structure

1. **Single Responsibility**: Each module has one clear purpose
2. **DRY**: No code duplication - shared functionality is centralized
3. **Maintainability**: Easy to find and modify specific features
4. **Testability**: Each module can be tested independently
5. **Scalability**: Easy to add new features without affecting existing code
6. **Readability**: Clear separation of concerns makes code easier to understand

## Usage

The modules are loaded in dependency order in `admin.html`:

1. `config.js` - Must be loaded first (used by all other modules)
2. `api.js` - Used by most other modules
3. `ui.js` - Utility functions used throughout
4. `map.js` - Map functionality
5. `websocket.js` - WebSocket connection
6. `userLocations.js` - Depends on map and websocket
7. `stats.js` - Statistics display
8. `players.js` - Player management
9. `qrCode.js` - QR code generation
10. `modal.js` - Modal functionality
11. `objects.js` - Object management
12. `main.js` - Initializes everything

## Global Objects

All managers are exposed as global objects for HTML onclick handlers:
- `UI` - UI utilities
- `MapManager` - Map operations
- `ObjectsManager` - Object operations
- `StatsManager` - Statistics operations
- `PlayersManager` - Player operations
- `WebSocketManager` - WebSocket operations
- `UserLocationsManager` - User location operations
- `QRCodeManager` - QR code operations
- `ModalManager` - Modal operations
- `App` - Main application



