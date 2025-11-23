# CacheRaiders API Server

Simple REST API for tracking loot box objects, their locations, and who found them.

## Features

- Track all loot box objects with their GPS coordinates
- Record who found which objects and when
- Query objects by location (radius-based)
- Get statistics and leaderboards
- SQLite database for simple deployment

## Quick Start

See [QUICKSTART.md](QUICKSTART.md) for a quick start guide.

## Setup

### Using Docker (Recommended)

1. Build and run:
```bash
docker-compose up -d
```

2. The API will be available at `http://localhost:5000`

### Manual Setup

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Run the server:
```bash
python app.py
```

## API Endpoints

### Health Check
- `GET /health` - Check if server is running

### Objects
- `GET /api/objects` - Get all objects
  - Query params: `latitude`, `longitude`, `radius` (meters), `include_found` (true/false)
- `GET /api/objects/<id>` - Get specific object
- `POST /api/objects` - Create new object
  ```json
  {
    "id": "uuid",
    "name": "Chalice",
    "type": "chalice",
    "latitude": 37.7749,
    "longitude": -122.4194,
    "radius": 5.0,
    "created_by": "user123"
  }
  ```

### Finds
- `POST /api/objects/<id>/found` - Mark object as found
  ```json
  {
    "found_by": "user123"
  }
  ```
- `DELETE /api/objects/<id>/found` - Unmark object (for testing)

### Users
- `GET /api/users/<user_id>/finds` - Get all objects found by user

### Statistics
- `GET /api/stats` - Get overall statistics and leaderboard

## Database

The SQLite database (`cache_raiders.db`) is created automatically on first run. It contains:

- `objects` table: All loot box objects
- `finds` table: Records of who found what and when

See [SCHEMA.md](SCHEMA.md) for detailed database schema documentation.

## iOS App Integration

The iOS app includes `APIService.swift` which provides methods to communicate with this API. To enable API sync:

1. Set the API base URL in your app (or use the default `http://localhost:5000` for local development)
2. Enable API sync in `LootBoxLocationManager`:
   ```swift
   locationManager.useAPISync = true
   ```
3. Load locations from API:
   ```swift
   await locationManager.loadLocationsFromAPI(userLocation: currentLocation)
   ```

The app will automatically sync when:
- Loading locations
- Marking objects as found
- Creating new objects

## Deployment

The Docker container can be deployed to any container hosting service:
- AWS ECS/Fargate
- Google Cloud Run
- Azure Container Instances
- DigitalOcean App Platform
- Railway
- Fly.io

For production, consider:
- Adding authentication/API keys
- Using PostgreSQL instead of SQLite for better concurrency
- Adding rate limiting
- Setting up proper logging
- Using HTTPS
- Adding CORS restrictions to specific domains

