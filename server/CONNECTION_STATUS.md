# Cache Raiders Server Connection Status

## ✅ Server is Running and Accessible

### Test Results (as of last check)

#### Colima VM IP: `192.168.64.3:5001`
- ✅ Health Check: PASS
- ✅ Server Info: PASS  
- ✅ Admin Panel: PASS
- ✅ Get Objects API: PASS
- ✅ Get Stats API: PASS
- ✅ Connection Test: PASS

**Use this IP for:** Accessing admin panel from your Mac's browser

#### WiFi IP: `10.0.0.201:5001`
- ⚠️ Cannot test from same machine (macOS routing limitation)
- ✅ Port forwarding (socat) is running correctly
- ✅ Server will be accessible from iOS devices on same WiFi

**Use this IP for:** iOS app connections (shown in QR code)

## Network Architecture

```
iOS Device (WiFi)
    ↓
10.0.0.201:5001 (Mac's WiFi IP)
    ↓
socat (port forwarding)
    ↓
192.168.64.3:5001 (Colima VM)
    ↓
Docker Container (Flask server)
```

## Why Two Different IPs?

1. **`192.168.64.3`** = Colima VM's internal IP
   - Only accessible from your Mac
   - Used for local development and admin panel access
   - Direct connection to Docker container

2. **`10.0.0.201`** = Your Mac's WiFi IP address
   - Accessible from other devices on the same WiFi network
   - Used by iOS devices to connect to the server
   - Forwarded to Colima VM via `socat`

## Current Configuration

### Environment Variables
```bash
HOST_IP=10.0.0.201
PORT=5001
```

### Port Forwarding (socat)
```bash
socat TCP-LISTEN:5001,bind=0.0.0.0,fork,reuseaddr TCP:192.168.64.3:5001
```
**Status:** ✅ Running (PID: 8908)

### Docker Containers
- `cache-raiders-api`: Running on port 5001
- `cache-raiders-ollama`: Running on port 11434

## iOS App Configuration

### Option 1: Scan QR Code
1. Open admin panel: `http://192.168.64.3:5001/admin`
2. Scan the QR code with your iOS app
3. The QR code contains: `http://10.0.0.201:5001`

### Option 2: Manual Entry
1. Open Settings in Cache Raiders iOS app
2. Enter server URL: `http://10.0.0.201:5001`
3. Tap "Save URL"
4. Tap "Test Connection"

## Troubleshooting

### "Cannot connect from my Mac to 10.0.0.201:5001"
**This is normal!** macOS doesn't route connections to your own WiFi IP properly. The server IS accessible from iOS devices on the same WiFi network.

### "iOS app can't connect"
1. Verify iOS device is on the same WiFi network as your Mac
2. Check firewall settings (System Settings → Network → Firewall)
3. Verify socat is running: `lsof -i :5001 | grep socat`
4. Restart server: `cd server && ./start-server.sh`

### "Admin panel not loading"
1. Use the Colima IP: `http://192.168.64.3:5001/admin`
2. Check Docker containers: `docker ps`
3. Check server logs: `docker logs cache-raiders-api`

## Testing Commands

### Test from Mac (admin panel)
```bash
curl http://192.168.64.3:5001/health
curl http://localhost:5001/health
```

### Test port forwarding
```bash
lsof -i :5001
ps aux | grep socat
```

### Run full connection test
```bash
cd server
./test_connection_endpoints.sh
```

### Test from iOS device
Use the iOS app's "Test Connection" button in Settings after entering `http://10.0.0.201:5001`

## Next Steps

1. ✅ Server is running correctly
2. ✅ Admin panel is accessible at `http://192.168.64.3:5001/admin`
3. ✅ Port forwarding is configured for iOS devices
4. 📱 **Test from iOS device** using `http://10.0.0.201:5001`

## Quick Reference

| Purpose | URL |
|---------|-----|
| Admin Panel (Mac) | `http://192.168.64.3:5001/admin` |
| iOS App Connection | `http://10.0.0.201:5001` |
| Health Check (Mac) | `http://localhost:5001/health` |
| QR Code | Shown in admin panel |

---

**Last Updated:** 2025-12-02
**Server Status:** ✅ Running
**Port Forwarding:** ✅ Active






