#!/bin/bash
# Script to fix and restart Docker Desktop

echo "🔧 Fixing Docker Desktop..."
echo ""

# Kill all Docker processes
echo "1. Killing all Docker processes..."
killall -9 "Docker Desktop" 2>/dev/null
killall -9 com.docker.backend 2>/dev/null
killall -9 com.docker.build 2>/dev/null
killall -9 "Docker Desktop Helper" 2>/dev/null
sleep 2
echo "   ✅ Done"

# Clean up lock files
echo ""
echo "2. Cleaning up lock files..."
rm -f ~/.docker/run/docker.sock.lock 2>/dev/null
rm -f ~/.docker/run/docker.sock 2>/dev/null
rm -f ~/Library/Containers/com.docker.docker/Data/*.lock 2>/dev/null
echo "   ✅ Done"

# Wait a bit
echo ""
echo "3. Waiting 5 seconds..."
sleep 5

# Try to start Docker Desktop
echo ""
echo "4. Attempting to start Docker Desktop..."
echo "   (If this doesn't work, start it manually from Applications)"

# Try different methods
if open -a Docker 2>/dev/null; then
    echo "   ✅ Started via 'open' command"
elif open "/Applications/Docker.app" 2>/dev/null; then
    echo "   ✅ Started via direct path"
else
    echo "   ⚠️  Could not start automatically"
    echo "   💡 Please start Docker Desktop manually:"
    echo "      - Press Cmd+Space, type 'Docker', press Enter"
    echo "      - OR: Finder → Applications → Docker"
fi

echo ""
echo "5. Waiting for Docker to initialize..."
echo "   (This may take 30-60 seconds)"
echo ""

# Wait and check
for i in {1..20}; do
    if docker info > /dev/null 2>&1; then
        echo ""
        echo "✅ Docker is ready!"
        docker info | grep -E "Server Version" | head -1
        exit 0
    fi
    sleep 3
    if [ $((i % 3)) -eq 0 ]; then
        echo "   Still waiting... ($(($i * 3))s)"
    fi
done

echo ""
echo "❌ Docker did not start within 60 seconds"
echo ""
echo "Next steps:"
echo "1. Check if Docker Desktop is running (look for whale icon in menu bar)"
echo "2. If not, start it manually from Applications"
echo "3. Wait for it to fully initialize"
echo "4. Then run: docker info"
echo ""
echo "If Docker Desktop still won't start, see FIX_DOCKER.md for more help"

