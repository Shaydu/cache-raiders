#!/bin/bash
# Setup script for Ollama container and model

set -e

echo "🚀 Setting up Ollama Container"
echo "=============================="
echo ""

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running!"
    echo "💡 Please start Docker Desktop first, then run this script again"
    exit 1
fi

cd "$(dirname "$0")"

# Start Ollama container
echo "1. Starting Ollama container..."
docker-compose up -d ollama

echo "   ⏳ Waiting for Ollama to start (10 seconds)..."
sleep 10

# Check if container is running
if ! docker ps --format "{{.Names}}" | grep -q "^cache-raiders-ollama$"; then
    echo "❌ Ollama container failed to start"
    echo "   Check logs: docker-compose logs ollama"
    exit 1
fi

echo "   ✅ Ollama container is running"
echo ""

# Check if model is already installed
echo "2. Checking for llama3.2:1b model..."
MODELS=$(docker exec cache-raiders-ollama ollama list 2>/dev/null | grep -c "llama3.2:1b" || echo "0")

if [ "$MODELS" -gt 0 ]; then
    echo "   ✅ Model llama3.2:1b is already installed"
else
    echo "   📥 Pulling llama3.2:1b model (this may take a few minutes)..."
    docker exec cache-raiders-ollama ollama pull llama3.2:1b
    
    if [ $? -eq 0 ]; then
        echo "   ✅ Model llama3.2:1b pulled successfully!"
    else
        echo "   ❌ Failed to pull model"
        exit 1
    fi
fi
echo ""

# Test Ollama API
echo "3. Testing Ollama API..."
if curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "   ✅ Ollama API is accessible"
    
    # List installed models
    echo "   📦 Installed models:"
    docker exec cache-raiders-ollama ollama list | tail -n +2 | awk '{print "      - " $1}'
else
    echo "   ❌ Cannot connect to Ollama API"
    exit 1
fi
echo ""

# Test chat API
echo "4. Testing chat API with llama3.2:1b..."
RESPONSE=$(curl -s --max-time 30 -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:1b", "messages": [{"role": "user", "content": "Say Ahoy in one word"}], "stream": false}' 2>/dev/null || echo "")

if [ -n "$RESPONSE" ] && echo "$RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'message' in data else 1)" 2>/dev/null; then
    CONTENT=$(echo "$RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('message', {}).get('content', '').strip())" 2>/dev/null || echo "")
    echo "   ✅ Chat API is working"
    echo "   📝 Response: $CONTENT"
else
    ERROR=$(echo "$RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Connection failed")
    echo "   ❌ Chat test failed: $ERROR"
    exit 1
fi
echo ""

echo "=============================="
echo "✅ Ollama setup complete!"
echo ""
echo "Next steps:"
echo "  1. Start the API container: docker-compose up -d api"
echo "  2. Run troubleshooting: ./troubleshoot_ollama.sh"
echo "  3. Test API endpoint: curl http://localhost:5001/api/llm/test-connection"
echo ""

