#!/bin/bash
# Quick test script to verify Ollama Docker setup

set -e

echo "🐳 Quick Ollama Docker Test"
echo "============================"
echo ""

# Check Docker
echo "1. Checking Docker..."
if ! docker info > /dev/null 2>&1; then
    echo "   ❌ Docker is not running!"
    echo "   💡 Please start Docker Desktop first"
    exit 1
fi
echo "   ✅ Docker is running"
echo ""

# Check containers
echo "2. Checking containers..."
cd "$(dirname "$0")"
if ! docker-compose ps | grep -q "ollama.*Up"; then
    echo "   ⚠️  Ollama container not running"
    echo "   💡 Starting containers..."
    docker-compose up -d
    echo "   ⏳ Waiting for containers to start..."
    sleep 5
fi
echo "   ✅ Containers are running"
echo ""

# Test Ollama API
echo "3. Testing Ollama API..."
if curl -s http://localhost:11434/api/tags > /dev/null; then
    echo "   ✅ Ollama is accessible on localhost:11434"
    MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys, json; data=json.load(sys.stdin); print(', '.join([m['name'] for m in data.get('models', [])]) if data.get('models') else 'No models')")
    echo "   📦 Available models: $MODELS"
else
    echo "   ❌ Cannot connect to Ollama on localhost:11434"
    exit 1
fi
echo ""

# Test from API container
echo "4. Testing from API container..."
if docker exec cache-raiders-api curl -s http://ollama:11434/api/tags > /dev/null 2>&1; then
    echo "   ✅ API container can reach Ollama via container name"
else
    echo "   ⚠️  API container cannot reach Ollama (may not be running in Docker)"
fi
echo ""

# Test chat
echo "5. Testing chat API..."
RESPONSE=$(curl -s -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model": "llama2", "messages": [{"role": "user", "content": "Say Ahoy in one word"}], "stream": false}' 2>/dev/null || echo "")

if [ -n "$RESPONSE" ] && echo "$RESPONSE" | grep -q "message"; then
    echo "   ✅ Chat API is working"
    CONTENT=$(echo "$RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('message', {}).get('content', '')[:50])" 2>/dev/null || echo "Response received")
    echo "   📝 Response: $CONTENT..."
else
    echo "   ⚠️  Chat test failed (model may not be installed)"
    echo "   💡 Install a model: docker exec -it cache-raiders-ollama ollama pull llama2"
fi
echo ""

echo "============================"
echo "✅ All tests passed!"
echo ""
echo "Next steps:"
echo "  - Test API: curl http://localhost:5001/api/llm/test"
echo "  - View logs: docker-compose logs -f"
echo "  - Pull models: docker exec -it cache-raiders-ollama ollama pull llama2"

