#!/bin/bash
# Unified CacheRaiders Server Startup Script
# Handles Colima VM, IP detection, Docker containers, and port forwarding
# Works for both local development and iOS device access

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="5001"

echo "🚀 Cache Raiders Server Startup"
echo "=============================="
echo "This script will:"
echo "  • Start Colima VM (if needed)"
echo "  • Detect your network IP"
echo "  • Start Docker containers"
echo "  • Set up port forwarding"
echo "  • Test everything works"
echo ""

# 1. Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found!"
    echo "   Make sure you're in the server directory"
    exit 1
fi

# 2. Detect host IP address
echo "🔍 Detecting network IP address..."
detect_host_ip() {
    echo "  Checking network interfaces..."

    # Method 1: Find the default route interface and get its IP
    default_iface=$(netstat -rn 2>/dev/null | grep -E '^default|^0\.0\.0\.0' | head -1 | awk '{print $NF}' || echo "")
    if [ -n "$default_iface" ]; then
        ip=$(ipconfig getifaddr $default_iface 2>/dev/null || echo "")
        if [ -n "$ip" ] && [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if [[ ! $ip =~ ^169\.254\. ]] && [[ ! $ip =~ ^192\.168\.64\. ]]; then
                echo "    Found IP via default route: $ip"
                echo "$ip"
                return 0
            fi
        fi
    fi

    # Method 2: Try common macOS WiFi/Ethernet interfaces
    for iface in en0 en1 en2 en3 en4 en5 en6 en7 en8 en9; do
        if ipconfig getifaddr $iface >/dev/null 2>&1; then
            ip=$(ipconfig getifaddr $iface 2>/dev/null)
            if [ -n "$ip" ] && [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                if [[ ! $ip =~ ^169\.254\. ]] && [[ ! $ip =~ ^192\.168\.64\. ]]; then
                    echo "    Found IP on $iface: $ip"
                    echo "$ip"
                    return 0
                fi
            fi
        fi
    done

    # Method 3: Fallback to ifconfig
    ip=$(ifconfig 2>/dev/null | grep -E "inet [0-9]" | grep -v 127.0.0.1 | grep -v 169.254 | grep -v 192.168.64 | awk '{print $2}' | head -1 || echo "")
    if [ -n "$ip" ]; then
        echo "    Found IP via ifconfig: $ip"
        echo "$ip"
        return 0
    fi

    return 1
}

# Use manually set HOST_IP or detect automatically
if [ -n "${HOST_IP:-}" ]; then
    echo "✅ Using manually set host IP: $HOST_IP"
else
    HOST_IP=$(detect_host_ip)
    if [ -n "$HOST_IP" ]; then
        echo "✅ Detected host IP: $HOST_IP"
        # Save for future use
        echo "$HOST_IP" > "$SCRIPT_DIR/.last_host_ip"
    else
        echo "❌ Could not detect host IP address"
        # Try saved IP
        if [ -f "$SCRIPT_DIR/.last_host_ip" ]; then
            saved_ip=$(cat "$SCRIPT_DIR/.last_host_ip" 2>/dev/null || echo "")
            if [ -n "$saved_ip" ]; then
                echo "📁 Using saved IP: $saved_ip"
                HOST_IP=$saved_ip
            fi
        fi

        if [ -z "$HOST_IP" ]; then
            echo ""
            echo "🔍 To find your IP:"
            echo "   ./detect_ip.sh"
            echo "   export HOST_IP=your_ip_here"
            exit 1
        fi
    fi
fi

# 3. Check/start Colima
echo ""
echo "🐳 Checking Colima VM..."
if ! colima status 2>/dev/null | grep -q "RUNNING"; then
    echo "⏳ Starting Colima..."
    colima start
    sleep 5
else
    echo "✅ Colima is running"
fi

# Get Colima IP
COLIMA_IP=$(colima status 2>&1 | grep "address:" | awk '{print $NF}' | tr -d '"' || echo "192.168.64.3")
echo "📍 Colima IP: $COLIMA_IP"

# 4. Clean up any existing processes
echo ""
echo "🧹 Cleaning up existing processes..."
pkill -f "socat.*$PORT" 2>/dev/null || true
docker compose down 2>/dev/null || true
sleep 2

# 5. Check Docker is available
echo ""
echo "🔍 Checking Docker..."
if ! docker ps >/dev/null 2>&1; then
    echo "❌ Docker is not accessible. Make sure Colima is running properly."
    exit 1
fi

# 6. Start containers
echo ""
echo "🐳 Starting Docker containers..."
docker compose up -d

echo "⏳ Waiting for containers to start..."
sleep 10

# 7. Check if containers started successfully
if ! docker ps --format "{{.Names}}" | grep -q "cache-raiders-api"; then
    echo "❌ API container failed to start"
    echo "   Check logs: docker compose logs api"
    exit 1
fi

echo "✅ Containers started successfully"

# 8. Set up port forwarding
echo ""
echo "🔁 Setting up port forwarding..."
echo "   From: $HOST_IP:$PORT (your Mac's WiFi IP)"
echo "   To: $COLIMA_IP:$PORT (Colima VM)"

# Start socat port forwarding
nohup socat TCP-LISTEN:$PORT,bind=$HOST_IP,reuseaddr,fork TCP:$COLIMA_IP:$PORT > "$SCRIPT_DIR/socat.log" 2>&1 &
sleep 2

# Verify port forwarding is working
if lsof -i :$PORT >/dev/null 2>&1; then
    echo "✅ Port forwarding active"
else
    echo "❌ Port forwarding failed"
fi

# 9. Test server health
echo ""
echo "🔍 Testing server health..."
sleep 3

if curl -s --max-time 10 http://$COLIMA_IP:$PORT/health | grep -q "healthy"; then
    echo "✅ Server is healthy!"
    SERVER_HEALTHY=true
else
    echo "⚠️  Server health check failed (may still be starting)"
    SERVER_HEALTHY=false
fi

# 10. Check Ollama
echo ""
echo "🧠 Checking Ollama models..."
if docker ps --format "{{.Names}}" | grep -q "cache-raiders-ollama"; then
    echo "✅ Ollama container is running"

    # Check for models
    MODELS=$(docker exec cache-raiders-ollama ollama list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' 2>/dev/null || echo "0")
    if [ "$MODELS" -gt 0 ]; then
        echo "✅ Found $MODELS model(s) in Ollama"
    else
        echo "⚠️  No models found in Ollama"
        echo "   You can pull a model later:"
        echo "   docker exec cache-raiders-ollama ollama pull llama3.2:1b"
    fi
else
    echo "⚠️  Ollama container not running"
fi

# 11. Final status and instructions
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "🎉 Cache Raiders Server Started!"
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "📱 Network Configuration:"
echo "   • Host IP (iOS devices): $HOST_IP"
echo "   • Colima VM IP: $COLIMA_IP"
echo "   • Port: $PORT"

echo ""
echo "🌐 Access URLs:"
echo "   • Admin Panel: http://$COLIMA_IP:$PORT/admin"
echo "   • iOS App URL: http://$HOST_IP:$PORT"
echo "   • API Health: http://$COLIMA_IP:$PORT/health"

echo ""
echo "🛠️  Management Commands:"
echo "   • View logs: docker compose logs -f"
echo "   • Stop server: docker compose down"
echo "   • Restart: ./start-unified.sh"

if [ "$SERVER_HEALTHY" = true ]; then
    echo ""
    echo "✅ Everything looks good! Your server is ready."
    echo "📱 iOS devices can now connect using: http://$HOST_IP:$PORT"
else
    echo ""
    echo "⚠️  Server may still be starting. Check health in a few seconds:"
    echo "   curl http://$COLIMA_IP:$PORT/health"
fi

echo ""
echo "💡 Need help? Run: ./detect_ip.sh or ./test_admin_panel.sh"
