# Debugging Connection Issues

This guide helps you debug why your iOS device can't connect to the server on the same local network.

## Quick Debug Steps

### 1. Check Server is Running
```bash
# From your Mac/computer running the server
curl http://localhost:5001/health
```

Should return: `{"status":"healthy",...}`

### 2. Find Your Server's IP Address

**On Mac:**
```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
```

**On Linux:**
```bash
ip addr show | grep "inet " | grep -v 127.0.0.1
```

**On Windows:**
```bash
ipconfig
```

Look for your WiFi/Ethernet adapter's IPv4 address (usually starts with `192.168.` or `10.`)

### 3. Test Connection from Your Computer

Use the test script:
```bash
cd server
python test_connection.py http://YOUR_IP:5001
```

Or test manually:
```bash
curl http://YOUR_IP:5001/health
curl http://YOUR_IP:5001/api/debug/connection-test
curl http://YOUR_IP:5001/api/debug/network-info
```

### 4. Check Server Logs

When you start the server, it should show:
```
🌐 Server running on:
   - Local: http://localhost:5001
   - Network: http://YOUR_IP:5001
```

When someone connects, you'll see:
```
🏥 Health check from CLIENT_IP (Host: ...)
📡 Server info requested from CLIENT_IP (Host: ...)
```

### 5. Test from iOS Device

1. **Get the server URL from admin panel:**
   - Open `http://YOUR_IP:5001/admin` in a browser
   - Look at the "Server Connection" section
   - Copy the server URL shown

2. **Enter URL in iOS app:**
   - Open Settings in the iOS app
   - Enter the server URL (e.g., `http://192.168.1.100:5001`)
   - Tap "Save URL"
   - Tap "Test Connection"

3. **Check for errors:**
   - If connection fails, check the error message
   - Common issues:
     - Wrong IP address
     - Firewall blocking port 5001
     - Device not on same WiFi network
     - Server not running

## Debug Endpoints

The server provides several debug endpoints:

### Health Check
```bash
curl http://YOUR_IP:5001/health
```
Returns basic server status.

### Connection Test
```bash
curl http://YOUR_IP:5001/api/debug/connection-test
```
Returns detailed connection information including:
- Your IP address as seen by the server
- Recommended server URL
- Network interfaces
- Platform information

### Network Info
```bash
curl http://YOUR_IP:5001/api/debug/network-info
```
Returns all network interfaces and recommended URLs.

### Server Info
```bash
curl http://YOUR_IP:5001/api/server-info
```
Returns server network configuration.

## Common Issues

### Issue: "Connection Refused"
**Cause:** Server not running or wrong IP address
**Fix:**
1. Make sure server is running: `python app.py`
2. Verify IP address with `ifconfig` or `ipconfig`
3. Try connecting from browser first: `http://YOUR_IP:5001/admin`

### Issue: "Connection Timeout"
**Cause:** Firewall blocking port 5001
**Fix:**
1. **On Mac:** System Settings → Network → Firewall → Options → Allow incoming connections for Python
2. **On Linux:** `sudo ufw allow 5001/tcp`
3. **On Windows:** Windows Defender Firewall → Allow an app → Python

### Issue: "Device not on same network"
**Cause:** iOS device and server on different networks
**Fix:**
1. Make sure both devices are on the same WiFi network
2. Check WiFi network name matches
3. Some routers have "Guest Network" isolation - disable it

### Issue: "Wrong IP address"
**Cause:** Using localhost or wrong network interface
**Fix:**
1. Don't use `localhost` or `127.0.0.1` from iOS device
2. Use the actual network IP (192.168.x.x or 10.x.x.x)
3. Get IP from admin panel or `ifconfig`/`ipconfig`

### Issue: "Server shows different IP"
**Cause:** Multiple network interfaces (WiFi + Ethernet)
**Fix:**
1. Check which interface is active: `ifconfig` or `ipconfig`
2. Use the IP from the active interface (usually `en0` on Mac for WiFi)
3. Or use the admin panel which shows the detected IP

## Testing Checklist

- [ ] Server is running (`python app.py`)
- [ ] Server shows network IP in startup logs
- [ ] Can access admin panel from browser: `http://YOUR_IP:5001/admin`
- [ ] Health check works: `curl http://YOUR_IP:5001/health`
- [ ] iOS device is on same WiFi network
- [ ] Firewall allows connections on port 5001
- [ ] Using network IP (not localhost) in iOS app
- [ ] Server logs show connection attempts

## Getting Help

If you're still having issues:

1. **Check server logs** - Look for connection attempts and errors
2. **Run test script** - `python test_connection.py http://YOUR_IP:5001`
3. **Check debug endpoints** - Use the endpoints above to see what the server detects
4. **Verify network** - Make sure both devices can ping each other (if ping is enabled)

## Network Configuration

The server binds to `0.0.0.0:5001` which means it accepts connections from:
- Localhost (127.0.0.1)
- All network interfaces (WiFi, Ethernet, etc.)

This is correct for local network access. If you need to restrict access, you can modify the `host` parameter in `app.py`.

