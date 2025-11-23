# Quick Start Guide

## 1. Start the API Server

### Option A: Using Docker Compose (Recommended)
```bash
cd server
docker-compose up -d
```

### Option B: Manual Python Setup
```bash
cd server
pip install -r requirements.txt
python app.py
```

The API will be available at `http://localhost:5001`

## 1.5. Access the Admin Web UI

Once the server is running, you can access the map-based admin interface at:

```
http://localhost:5001/admin
```

This web UI allows you to:
- View all objects on an interactive map
- Click on the map to place new objects
- Set object name, type, and radius
- View statistics (total objects, found objects, etc.)
- Delete objects
- See which objects have been collected

The admin UI automatically refreshes every 30 seconds to show the latest data.

## 2. Test the API

### Health Check
```bash
curl http://localhost:5001/health
```

### Create an Object
```bash
curl -X POST http://localhost:5001/api/objects \
  -H "Content-Type: application/json" \
  -d '{
    "id": "test-123",
    "name": "Test Chalice",
    "type": "Chalice",
    "latitude": 37.7749,
    "longitude": -122.4194,
    "radius": 5.0,
    "created_by": "user1"
  }'
```

### Get All Objects
```bash
curl http://localhost:5001/api/objects
```

### Mark Object as Found
```bash
curl -X POST http://localhost:5001/api/objects/test-123/found \
  -H "Content-Type: application/json" \
  -d '{"found_by": "user1"}'
```

### Get Statistics
```bash
curl http://localhost:5001/api/stats
```

### Delete an Object
```bash
curl -X DELETE http://localhost:5001/api/objects/test-123
```

## 3. Configure iOS App

1. **Set API URL** (if not using localhost):
   ```swift
   UserDefaults.standard.set("https://your-api-url.com", forKey: "apiBaseURL")
   ```

2. **Enable API Sync**:
   ```swift
   locationManager.useAPISync = true
   ```

3. **Load from API**:
   ```swift
   await locationManager.loadLocationsFromAPI(userLocation: currentLocation)
   ```

## 4. For Production Deployment

1. Update `baseURL` in `APIService.swift` or set via UserDefaults
2. Deploy the Docker container to your hosting service
3. Update the API URL in your app
4. Consider adding authentication/API keys

## Troubleshooting

- **API not responding**: Check if the server is running and accessible
- **CORS errors**: The server has CORS enabled, but make sure your API URL is correct
- **Database issues**: The database file is created automatically. Make sure the container has write permissions.

