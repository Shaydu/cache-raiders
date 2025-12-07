#!/bin/bash
# Complete server restart script

set -e

echo "🔄 Complete Cache Raiders Server Restart"
echo "========================================"

# Clean up any existing processes
echo "1. Cleaning up existing processes..."
pkill -f "socat.*5001" 2>/dev/null || true
docker compose down 2>/dev/null || true

# Start fresh
echo "2. Starting Colima..."
colima start

echo "3. Setting up environment..."
export HOST_IP="${HOST_IP:-10.0.0.131}"
cd "$(dirname "$0")"

echo "4. Starting containers..."
docker compose up -d

echo "5. Waiting for containers to be ready..."
sleep 15

echo "6. Setting up port forwarding..."
# Kill any existing socat
pkill -f "socat.*5001" 2>/dev/null || true
sleep 1

# Start new socat
nohup socat TCP-LISTEN:5001,bind=$HOST_IP,reuseaddr,fork TCP:192.168.64.3:5001 > socat.log 2>&1 &
echo "✅ Port forwarding started"

echo "7. Testing server health..."
sleep 5

if curl -s --max-time 10 http://192.168.64.3:5001/health | grep -q "healthy"; then
    echo "✅ Server is healthy!"
    echo ""
    echo "🎉 Admin panel available at:"
    echo "   http://192.168.64.3:5001/admin"
    echo "   http://$HOST_IP:5001/admin"
else
    echo "❌ Server health check failed"
    echo "   Check logs: docker logs cache-raiders-api"
fi
