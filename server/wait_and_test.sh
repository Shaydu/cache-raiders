#!/bin/bash
# Wait for Docker to start, then automatically start containers and run tests

echo "🐳 Docker Auto-Test Script"
echo "=========================="
echo ""
echo "📋 Instructions:"
echo "   1. Start Docker Desktop from Applications (or press Cmd+Space, type 'Docker')"
echo "   2. Wait for Docker to fully start (whale icon in menu bar should be steady)"
echo "   3. This script will automatically detect when Docker is ready"
echo ""
echo "⏳ Waiting for Docker to start..."
echo "   (Press Ctrl+C to cancel)"
echo ""

# Wait for Docker (up to 5 minutes)
MAX_WAIT=300
WAITED=0
CHECK_INTERVAL=3

while ! docker info > /dev/null 2>&1; do
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo ""
        echo "❌ Docker did not start within 5 minutes"
        echo "💡 Please start Docker Desktop manually and run this script again"
        exit 1
    fi
    sleep $CHECK_INTERVAL
    WAITED=$((WAITED + CHECK_INTERVAL))
    if [ $((WAITED % 15)) -eq 0 ]; then
        echo "   Still waiting... (${WAITED}s) - Make sure Docker Desktop is starting..."
    fi
done

echo ""
echo "✅ Docker is running!"
echo ""

# Change to script directory
cd "$(dirname "$0")"

# Start containers
echo "🚀 Starting Docker containers..."
docker-compose up -d

echo ""
echo "⏳ Waiting for containers to be ready..."
sleep 8

# Show container status
echo ""
echo "📊 Container Status:"
docker-compose ps

echo ""
echo "🧪 Running comprehensive tests..."
echo ""
python3 test_ollama_docker.py

TEST_RESULT=$?

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo "✅ All tests passed! Ollama is running and accessible."
    echo ""
    echo "Next steps:"
    echo "  - Test API endpoint: curl http://localhost:5001/api/llm/test"
    echo "  - View logs: docker-compose logs -f"
    echo "  - Pull a model: docker exec -it cache-raiders-ollama ollama pull llama2"
else
    echo "⚠️  Some tests failed. Check the output above for details."
fi

exit $TEST_RESULT

