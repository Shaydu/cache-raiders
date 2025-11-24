# Debugging Multiple Users on Admin Panel

## Current Status

The admin panel should display multiple users as blue pins with player names. If you're only seeing one user, here's how to debug:

## Check Server Logs

The server now has enhanced logging. Check logs with:

```bash
docker-compose logs -f api
```

Look for:
- `📍 User location updated: ...` - Shows when location updates are received
- `Total users in memory: X` - Shows how many users are stored
- `User UUIDs: [...]` - Lists all device UUIDs
- `📍 Returning X active user locations` - Shows what's being returned to admin panel

## Check Active Locations API

Test what the API is returning:

```bash
curl http://localhost:5001/api/users/locations | python3 -m json.tool
```

This shows all active user locations. Each device UUID should appear as a separate entry.

## Check Browser Console

Open the admin panel (http://localhost:5001/admin) and open browser console (F12 → Console).

Look for:
- `Loaded user locations: X active users` - Should show number of active users
- `📍 Processing user location: ...` - One log per user being processed
- `✅ Added blue dot for user: ...` - Confirms markers are created

## Common Issues

### 1. Second User Not Sending Location Updates

**Check:**
- Is the second iOS app running?
- Has the second user tapped the GPS direction box to send location?
- Does the second user have location permissions granted?
- Is the second user's device connected to the same network as the server?

**Solution:**
- Each user must manually tap the GPS direction box to send their location
- Location updates are NOT automatic - they're sent on-demand when user taps

### 2. Same Device UUID

**Check:**
- Are both users on the same physical device/simulator?
- `UIDevice.current.identifierForVendor` returns the same UUID for the same device

**Solution:**
- Each user needs to be on a different physical device
- Simulators on the same Mac will have different UUIDs, but real devices are needed for actual testing

### 3. Location Expired

**Check:**
- Locations expire after 5 minutes of inactivity
- If a user hasn't sent an update in 5+ minutes, they won't appear

**Solution:**
- Have users tap the GPS direction box again to refresh their location

### 4. Network Issues

**Check:**
- Can both devices reach the server?
- Are they on the same network?
- Is the server IP correct in both apps' settings?

**Solution:**
- Verify server IP in Settings → API Base URL
- Test connectivity: `curl http://<server-ip>:5001/health`

## Test Script

Use the test script to verify multiple users work:

```bash
python3 test_multiple_users.py
```

This creates 3 test users and sends location updates for each. You should see all 3 appear on the admin panel.

## Expected Behavior

When working correctly:
1. Each user taps GPS direction box → sends location update
2. Server receives update → stores in `user_locations` dictionary
3. Admin panel polls every 5 seconds → fetches all active locations
4. Admin panel creates/updates blue pin for each user
5. Each pin shows player name below it

## Debugging Steps

1. **Check server logs** - See if location updates are being received
2. **Check API response** - Verify multiple users in `/api/users/locations`
3. **Check browser console** - See if admin panel is processing multiple users
4. **Check iOS app** - Verify second user is actually sending updates
5. **Check network** - Ensure both devices can reach server

## Enhanced Logging

The server now logs:
- When location updates are received
- Total users in memory
- List of all device UUIDs
- What's being returned to admin panel

The admin panel now logs:
- Number of active users loaded
- Each user being processed
- When markers are created/updated

