# Testing API Integration

## Current Status

✅ **API Server**: Running on `http://localhost:5001`  
✅ **Database Schema**: Created and initialized  
✅ **iOS Integration**: Code added, but **NOT enabled by default**

## How to Test

### 1. Verify API Server is Running

```bash
curl http://localhost:5001/health
```

Should return:
```json
{
    "status": "healthy",
    "timestamp": "2025-11-23T..."
}
```

### 2. Enable API Sync in iOS App

1. **Build and run** your iOS app
2. Open **Settings** (gear icon in top right)
3. Scroll to **"API Sync"** section
4. **Toggle "Enable API Sync"** to ON
5. The app will automatically try to load locations from the API

### 3. Test Creating Objects

**Option A: Via iOS App**
1. Open the map view (map icon)
2. Add a new loot box location
3. It should sync to the API automatically

**Option B: Via API directly**
```bash
curl -X POST http://localhost:5001/api/objects \
  -H "Content-Type: application/json" \
  -d '{
    "id": "test-chalice-1",
    "name": "Test Chalice",
    "type": "Chalice",
    "latitude": 37.7749,
    "longitude": -122.4194,
    "radius": 5.0,
    "created_by": "test-user"
  }'
```

### 4. Verify Objects in API

```bash
curl http://localhost:5001/api/objects | python3 -m json.tool
```

### 5. Test Finding Objects

1. In the iOS app, find and tap a loot box
2. It should mark as found in the API
3. Verify:
```bash
curl http://localhost:5001/api/objects | python3 -m json.tool
```
The object should show `"collected": true` and have `found_by` and `found_at` fields.

### 6. Test Multi-Device Sync

1. **Device 1**: Enable API sync, create/find objects
2. **Device 2**: Enable API sync, refresh from API
3. Device 2 should see the same objects and their found status

## Database Schema

See `server/SCHEMA.md` for full schema documentation.

**Tables:**
- `objects`: All loot box objects with GPS coordinates
- `finds`: Who found which objects and when

## Troubleshooting

### API Not Responding
- Check if server is running: `lsof -i :5001`
- Check server logs in terminal
- Verify database exists: `ls server/cache_raiders.db`

### iOS App Can't Connect
- Verify API URL in `APIService.swift` (default: `http://localhost:5001`)
- For iOS Simulator: `localhost` works
- For Physical Device: Use your Mac's IP address (e.g., `http://192.168.1.100:5001`)
- Check network connectivity

### Objects Not Syncing
- Verify "Enable API Sync" toggle is ON in Settings
- Check Xcode console for API error messages
- Verify API server is accessible from device

### Database Issues
- Database file: `server/cache_raiders.db`
- To reset: Delete the file and restart server
- To inspect: `sqlite3 server/cache_raiders.db`

## API Endpoints

- `GET /health` - Health check
- `GET /api/objects` - Get all objects
- `GET /api/objects/<id>` - Get specific object
- `POST /api/objects` - Create object
- `POST /api/objects/<id>/found` - Mark as found
- `DELETE /api/objects/<id>/found` - Unmark (for testing)
- `GET /api/users/<user_id>/finds` - Get user's finds
- `GET /api/stats` - Get statistics

## Next Steps

1. ✅ Enable API sync in Settings
2. ✅ Test creating objects
3. ✅ Test finding objects
4. ✅ Test multi-device sync
5. Deploy API to production server
6. Update API URL in app for production



