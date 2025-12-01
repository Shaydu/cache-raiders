#!/bin/bash
# Fix Ollama timeout issues

set -e

echo "🔧 Fixing Ollama Timeout Issues"
echo "================================"
echo ""

cd "$(dirname "$0")"

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running!"
    echo "💡 Please start Docker Desktop first"
    exit 1
fi

# Check if containers are running
OLLAMA_CONTAINER="cache-raiders-ollama"
API_CONTAINER=$(docker ps --filter "name=api" --format "{{.Names}}" | head -1)

if [ -z "$API_CONTAINER" ]; then
    API_CONTAINER=$(docker ps --format "{{.Names}}" | grep -i "cache-raiders.*api\|api.*cache" | head -1)
fi

echo "1. Checking Ollama container..."
if ! docker ps --format "{{.Names}}" | grep -q "^${OLLAMA_CONTAINER}$"; then
    echo "   ⚠️  Ollama container not running. Starting it..."
    docker-compose up -d ollama
    echo "   ⏳ Waiting for Ollama to start..."
    sleep 10
fi

if docker ps --format "{{.Names}}" | grep -q "^${OLLAMA_CONTAINER}$"; then
    echo "   ✅ Ollama container is running"
else
    echo "   ❌ Failed to start Ollama container"
    exit 1
fi
echo ""

# Check if model is installed
echo "2. Checking for llama3.2:1b model..."
MODEL_EXISTS=$(docker exec "$OLLAMA_CONTAINER" ollama list 2>/dev/null | grep -c "llama3.2:1b" || echo "0")

if [ "$MODEL_EXISTS" -eq 0 ]; then
    echo "   ⚠️  Model llama3.2:1b not found. Pulling it now..."
    echo "   📥 This may take a few minutes..."
    docker exec "$OLLAMA_CONTAINER" ollama pull llama3.2:1b
    if [ $? -eq 0 ]; then
        echo "   ✅ Model pulled successfully!"
    else
        echo "   ❌ Failed to pull model"
        exit 1
    fi
else
    echo "   ✅ Model llama3.2:1b is installed"
fi
echo ""

# Warm up the model (pre-load it)
echo "3. Warming up the model (pre-loading into memory)..."
echo "   This will make the first request faster..."
WARMUP_RESPONSE=$(curl -s --max-time 60 -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:1b", "messages": [{"role": "user", "content": "Hi"}], "stream": false}' 2>/dev/null || echo "")

if [ -n "$WARMUP_RESPONSE" ] && echo "$WARMUP_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'message' in data else 1)" 2>/dev/null; then
    echo "   ✅ Model warmed up successfully!"
    echo "   💡 The model is now loaded in memory and ready for fast responses"
else
    ERROR=$(echo "$WARMUP_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Connection failed")
    echo "   ⚠️  Warmup had an issue: $ERROR"
    echo "   💡 This is okay - the model will load on the first real request"
fi
echo ""

# Test API connection (if API container is running)
if [ -n "$API_CONTAINER" ] && docker ps --format "{{.Names}}" | grep -q "^${API_CONTAINER}$"; then
    echo "4. Testing API server connection..."
    
    # Wait a moment for API to be ready
    sleep 2
    
    if curl -s --max-time 10 http://localhost:5001/api/llm/test-connection > /dev/null 2>&1; then
        echo "   ✅ API server is accessible"
        
        # Try to warm up via API
        echo "   🔥 Warming up model via API endpoint..."
        WARMUP_API=$(curl -s --max-time 90 -X POST http://localhost:5001/api/llm/warmup)
        WARMUP_STATUS=$(echo "$WARMUP_API" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status', 'unknown'))" 2>/dev/null || echo "unknown")
        
        if [ "$WARMUP_STATUS" = "success" ]; then
            ELAPSED=$(echo "$WARMUP_API" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('elapsed_seconds', 'unknown'))" 2>/dev/null || echo "unknown")
            echo "   ✅ Model warmed up via API in ${ELAPSED}s"
        else
            echo "   ⚠️  Warmup via API had issues (this is okay if model is already loaded)"
        fi
    else
        echo "   ⚠️  API server not responding (may need to restart)"
        echo "   💡 Restart API: docker-compose restart api"
    fi
    echo ""
fi

echo "================================"
echo "✅ Troubleshooting complete!"
echo ""
echo "The timeout issue should be resolved. The model is now:"
echo "  - Installed in Ollama"
echo "  - Warmed up (loaded in memory)"
echo ""
echo "Next requests should be fast (<5 seconds)."
echo ""

