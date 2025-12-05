#!/bin/bash
# Automatically wait for Docker, start containers, and run tests

set -e

echo "🐳 Auto Start and Test Script"
echo "=============================="
echo ""

# Wait for Docker to be available
echo "⏳ Waiting for Docker to start..."
MAX_WAIT=120  # 2 minutes
WAITED=0

while ! docker info > /dev/null 2>&1; do
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "❌ Docker did not start within $MAX_WAIT seconds"
        echo "💡 Please start Docker Desktop manually and run this script again"
        exit 1
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $((WAITED % 10)) -eq 0 ]; then
        echo "   Still waiting... (${WAITED}s/${MAX_WAIT}s)"
    fi
done

echo "✅ Docker is running!"
echo ""

# Start containers
echo "🚀 Starting containers..."
cd "$(dirname "$0")"
docker-compose up -d

echo "⏳ Waiting for containers to be ready..."
sleep 5

# Check container status
echo ""
echo "📊 Container Status:"
docker-compose ps

echo ""
echo "🧪 Running comprehensive tests..."
python3 test_ollama_docker.py

echo ""
echo "✅ All done!"

