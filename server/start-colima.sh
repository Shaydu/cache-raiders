#!/bin/bash
# CacheRaiders Server Startup Script
# This script starts Colima, Docker containers, and sets up port forwarding

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLIMA_IP="192.168.64.3"
PORT="5001"

echo "🚀 Starting CacheRaiders Server..."

# 1. Detect Mac's network IP address for iOS devices to connect
# Try Ethernet first (en0), then WiFi (en1), then other interfaces
echo "🔍 Detecting network IP address..."

# Try Ethernet interface first (en0)
export HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
if [ -n "$HOST_IP" ]; then
    echo "🔌 Using Ethernet IP: $HOST_IP"
else
    # Try WiFi interface (en1)
    HOST_IP=$(ipconfig getifaddr en1 2>/dev/null || echo "")
    if [ -n "$HOST_IP" ]; then
        echo "📶 Using WiFi IP: $HOST_IP"
    else
        # Try other common interfaces
        for iface in en2 en3 en4; do
            ip=$(ipconfig getifaddr $iface 2>/dev/null || echo "")
            if [ -n "$ip" ]; then
                HOST_IP=$ip
                echo "📡 Using $iface IP: $HOST_IP"
                break
            fi
        done
    fi
fi

if [ -z "$HOST_IP" ]; then
    echo "❌ ERROR: Could not detect your Mac's IP address!"
    echo "   Make sure you're connected to a network (Ethernet or Wi-Fi)."
    echo "   You can manually set HOST_IP:"
    echo "   export HOST_IP=192.168.1.XXX  # Replace with your actual IP"
    echo "   Then run: docker compose up -d"
    exit 1
fi

echo "📱 Host IP for iOS: $HOST_IP"

# Save the detected IP for future reference
echo "$HOST_IP" > "$SCRIPT_DIR/.last_host_ip"

# 2. Check if Colima is running
echo "🐳 Checking Colima status..."
if ! colima status 2>/dev/null | grep -q "RUNNING"; then
    echo "⏳ Starting Colima..."
    colima start
    sleep 5
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
    sleep 3
    docker compose up -d
    sleep 10
elif docker compose ps 2>/dev/null | grep -q "Up"; then
    echo "✅ Containers already running with correct HOST_IP: $HOST_IP"
else
    echo "🚀 Starting Docker containers..."
    docker compose up -d
    sleep 10
fi

# 4. Set up port forwarding (if not already running)
echo "🔁 Setting up port forwarding from $HOST_IP:$PORT to $COLIMA_IP:$PORT..."

# Check if socat is already running for this port
if ! lsof -i :$PORT | grep -q socat; then
    echo "🔁 Starting socat port forwarder..."
    # Kill any existing socat processes on this port
    pkill -f "socat.*:$PORT" 2>/dev/null || true
    sleep 1
    
    # Start socat to forward traffic from host IP to Colima
    nohup socat TCP-LISTEN:$PORT,bind=$HOST_IP,reuseaddr,fork TCP:$COLIMA_IP:$PORT > "$SCRIPT_DIR/socat.log" 2>&1 &
    echo "✅ Port forwarding started"
else
    echo "✅ Port forwarding already active"
fi

# 5. Verify server is running
echo "🔍 Verifying server health..."

# First try Colima IP (direct container access)
if curl -s --max-time 5 http://$COLIMA_IP:$PORT/health | grep -q "healthy"; then
    echo "✅ Server is healthy on Colima IP: $COLIMA_IP:$PORT"
else
    echo "⚠️  Server not responding on Colima IP"
fi

# Verify using the detected HOST_IP
if [ "$HOST_IP" != "localhost" ] && [ -n "$HOST_IP" ]; then
    if curl -s --max-time 5 http://$HOST_IP:$PORT/health | grep -q "healthy"; then
        echo "✅ Server is healthy on $HOST_IP:$PORT"
    else
        echo "⚠️  External IP check failed"
        echo "   This is normal if you just started the server - it may take a few seconds"
    fi
fi

# 6. Show connection information
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎮 iOS Connection URL: http://$HOST_IP:$PORT"
echo "📊 Admin Panel: http://$HOST_IP:$PORT/admin"
echo "📊 Colima Admin: http://$COLIMA_IP:$PORT/admin"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 7. Check if Ollama has models, if not suggest pulling one
echo "🔍 Checking Ollama models..."
if docker ps | grep -q cache-raiders-ollama; then
    MODELS=$(docker exec cache-raiders-ollama ollama list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    if [ "$MODELS" -eq 0 ] || [ -z "$MODELS" ]; then
        echo "⚠️  No models found in Ollama container"
        echo "   You can pull a model later with:"
        echo "   docker exec cache-raiders-ollama ollama pull llama3.2:1b"
    else
        echo "✅ Found $MODELS model(s) in Ollama"
    fi
fi

echo ""
echo "🎉 Server setup complete!"
echo "📱 Open the iOS app and scan the QR code from the admin panel"
echo "💡 Or manually enter: http://$HOST_IP:$PORT"
echo ""