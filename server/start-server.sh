#!/bin/bash
# CacheRaiders Server Startup Script
# This script starts Colima, Docker containers, and sets up port forwarding

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLIMA_IP="192.168.64.3"
PORT="5001"

echo "🚀 Starting CacheRaiders Server..."

# 1. Detect Mac's WiFi IP address for iOS devices to connect
export HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
if [ -z "$HOST_IP" ]; then
    # Try en1 as fallback (some Macs use this for WiFi)
    HOST_IP=$(ipconfig getifaddr en1 2>/dev/null || echo "")
fi

if [ -z "$HOST_IP" ]; then
    echo "❌ ERROR: Could not detect your Mac's IP address!"
    echo "   Make sure you're connected to Wi-Fi."
    echo "   You can manually set HOST_IP:"
    echo "   export HOST_IP=192.168.1.XXX  # Replace with your actual IP"
    echo "   Then run: docker compose up -d"
    exit 1
fi

echo "📱 Host IP for iOS: $HOST_IP"

# Save the detected IP for future reference
echo "$HOST_IP" > "$SCRIPT_DIR/.last_host_ip"

# 2. Check if Colima is running
if ! colima status &>/dev/null; then
    echo "📦 Starting Colima..."
    colima start --cpu 4 --memory 8 --disk 60 --network-address --network-host-addresses
    sleep 5
else
    echo "✅ Colima is already running"
fi

# Get Colima's IP (strip any quotes or extra characters)
COLIMA_IP=$(colima status 2>&1 | grep "address:" | awk '{print $NF}' | tr -d '"')
if [ -z "$COLIMA_IP" ]; then
    COLIMA_IP="192.168.64.3"
fi
echo "📍 Colima IP: $COLIMA_IP"

# 3. Check if HOST_IP has changed and restart containers if needed
echo "🐳 Checking Docker containers..."
cd "$SCRIPT_DIR"

# Check if containers are running and if HOST_IP matches
CURRENT_HOST_IP=$(docker inspect server-api-1 2>/dev/null | grep -o '"HOST_IP=[^"]*"' | cut -d= -f2 | tr -d '"' || echo "")

if [ -n "$CURRENT_HOST_IP" ] && [ "$CURRENT_HOST_IP" != "$HOST_IP" ]; then
    echo "⚠️  HOST_IP changed from $CURRENT_HOST_IP to $HOST_IP"
    echo "🔄 Restarting containers with new IP..."
    docker compose down
    docker compose up -d
    echo "⏳ Waiting for containers to start..."
    sleep 10
elif docker compose ps 2>/dev/null | grep -q "Up"; then
    echo "✅ Containers already running with correct HOST_IP: $HOST_IP"
else
    echo "🚀 Starting Docker containers..."
    docker compose up -d
    echo "⏳ Waiting for containers to start..."
    sleep 10
fi

# 4. Set up port forwarding with socat
echo "🔌 Setting up port forwarding..."

# Kill any existing socat or broken docker-proxy on port 5001
lsof -ti :$PORT 2>/dev/null | while read pid; do
    # Don't kill our own socat if it's working
    if ! ps -p $pid -o comm= 2>/dev/null | grep -q socat; then
        kill -9 $pid 2>/dev/null || true
    fi
done
sleep 1

# Kill any existing socat processes for this port
pkill -f "socat.*$PORT" 2>/dev/null || true
sleep 1

# Start socat port forwarding
socat TCP-LISTEN:$PORT,bind=0.0.0.0,fork,reuseaddr TCP:$COLIMA_IP:$PORT &
SOCAT_PID=$!
sleep 2

# 5. Verify everything is working
echo "🔍 Verifying server..."
if curl -s --max-time 5 http://127.0.0.1:$PORT/health | grep -q "healthy"; then
    echo "✅ Server is healthy on localhost:$PORT"
else
    echo "⚠️  localhost check failed, trying Colima IP directly..."
fi

# Verify using the detected HOST_IP
if [ "$HOST_IP" != "localhost" ] && [ -n "$HOST_IP" ]; then
    if curl -s --max-time 5 http://$HOST_IP:$PORT/health | grep -q "healthy"; then
        echo "✅ Server is healthy on $HOST_IP:$PORT"
    else
        echo "⚠️  External IP check failed"
    fi
fi

echo ""
echo "📊 Container status:"
docker compose ps

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎮 iOS Connection URL: http://$HOST_IP:$PORT"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "💡 To stop: cd $SCRIPT_DIR && docker compose down && pkill -f 'socat.*$PORT'"
echo "💡 socat PID: $SOCAT_PID"

