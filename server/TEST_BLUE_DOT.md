# Testing Blue Dot in Admin Interface

## Overview
This guide helps you test that user location (blue dot) appears in the admin interface both from:
1. Manual API calls (for testing)
2. iOS app location updates (real device)

## Prerequisites
- Server running on `http://localhost:5001`
- Admin interface accessible at `http://localhost:5001/admin.html`

## Step 1: Test with Manual API Call

### Option A: Using curl
```bash
# Create a test user location
curl -X POST http://localhost:5001/api/users/test-device-123/location \
  -H "Content-Type: application/json" \
  -d '{
    "latitude": 40.0758,
    "longitude": -105.3008,
    "accuracy": 10.5,
    "heading": 45.0
  }'

# Verify it was stored
curl http://localhost:5001/api/users/locations
```

### Option B: Using Python script
```bash
cd server
python3 test_admin_blue_dot.py
```

## Step 2: Verify in Admin Interface

1. Open `http://localhost:5001/admin.html` in your browser
2. Look for a **blue dot** on the map
3. The blue dot should:
   - Be larger than object markers (22px vs smaller)
   - Have a blue color (#2196F3)
   - Show a white border and shadow
   - Display player name when clicked
   - Show location coordinates, accuracy, and heading

4. The admin interface refreshes user locations every 10 seconds
   - If you don't see it immediately, wait up to 10 seconds
   - Or manually refresh the page

## Step 3: Test from iOS App

### Verify iOS App is Sending Location Updates

The iOS app sends location updates in two ways:

1. **On every location update** (when user moves):
   - `UserLocationManager.locationManager(_:didUpdateLocations:)` 
   - Sends immediately when CoreLocation provides new location

2. **Periodic updates** (every 10 seconds):
   - Timer in `UserLocationManager.startPeriodicLocationUpdates()`
   - Ensures location is sent even if user isn't moving

### Check iOS App Code

The location update is sent via:
- `APIService.shared.updateUserLocation(latitude:longitude:accuracy:heading:)`
- Endpoint: `POST /api/users/{device_uuid}/location`
- Device UUID comes from `APIService.currentUserID` (device identifier)

### Testing Steps

1. **Run the iOS app** on a device or simulator
2. **Grant location permissions** when prompted
3. **Open the AR view** (this starts location updates)
4. **Check server logs** - you should see:
   ```
   📍 User location updated: {device_uuid}... at (lat, lon)
   ```
5. **Open admin interface** - blue dot should appear within 10 seconds
6. **Move the device** - blue dot should update position

## Troubleshooting

### Blue dot doesn't appear

1. **Check server is running**: `curl http://localhost:5001/health`
2. **Check location was sent**: `curl http://localhost:5001/api/users/locations`
3. **Check server logs** for errors
4. **Verify device UUID** matches what's in the database
5. **Check browser console** in admin.html for JavaScript errors

### Location updates not working from iOS

1. **Check location permissions** are granted
2. **Check API base URL** in app settings matches server
3. **Check server logs** for incoming requests
4. **Verify network connectivity** between device and server
5. **Check Xcode console** for error messages

### Route 404 errors

If you see 404 errors for `/api/users/{uuid}/location`:
- The server may need to be restarted
- Check the route is registered: `python3 -c "import app; print([r.rule for r in app.app.url_map.iter_rules()])"`
- Verify Flask-SocketIO is running correctly

## Expected Behavior

✅ **Working correctly:**
- Blue dot appears on map within 10 seconds of location update
- Blue dot updates position when user moves
- Blue dot shows player name when clicked
- Multiple users show as multiple blue dots
- Blue dots disappear when users stop sending updates (after 5 minutes)

❌ **Not working:**
- No blue dot appears
- Blue dot appears but doesn't update
- Blue dot appears in wrong location
- JavaScript errors in browser console

## Next Steps

Once manual testing works, test with the iOS app:
1. Ensure app has location permissions
2. Run app and navigate to AR view
3. Watch admin interface for blue dot to appear
4. Move device and verify blue dot updates

