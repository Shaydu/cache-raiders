#!/bin/bash
# Setup granite4:350m model and test it

set -e

echo "🚀 Setting up Granite4:350m Model"
echo "=================================="
echo ""

cd "$(dirname "$0")"

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running!"
    echo "💡 Please start Docker Desktop first"
    exit 1
fi

MODEL="granite4:350m"

# Step 1: Start Ollama container
echo "1. Starting Ollama container..."
docker-compose up -d ollama
echo "   ⏳ Waiting for Ollama to start..."
sleep 10

# Check if Ollama is running
if ! docker ps --format "{{.Names}}" | grep -q "^cache-raiders-ollama$"; then
    echo "   ❌ Ollama container failed to start"
    echo "   Check logs: docker-compose logs ollama"
    exit 1
fi
echo "   ✅ Ollama container is running"
echo ""

# Step 2: Wait for Ollama API to be ready
echo "2. Waiting for Ollama API to be ready..."
for i in {1..30}; do
    if curl -s --max-time 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "   ✅ Ollama API is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "   ⚠️  Ollama API took longer than expected, but continuing..."
    fi
    sleep 1
done
echo ""

# Step 3: Check if model is installed
echo "3. Checking if $MODEL is installed..."
MODEL_EXISTS=$(docker exec cache-raiders-ollama ollama list 2>/dev/null | grep -c "$MODEL" || echo "0")

if [ "$MODEL_EXISTS" -eq 0 ]; then
    echo "   📥 Pulling $MODEL (this may take a few minutes)..."
    docker exec cache-raiders-ollama ollama pull "$MODEL"
    
    if [ $? -eq 0 ]; then
        echo "   ✅ Model $MODEL pulled successfully!"
    else
        echo "   ❌ Failed to pull model"
        exit 1
    fi
else
    echo "   ✅ Model $MODEL is already installed"
fi
echo ""

# Step 4: Pre-load the model
echo "4. Pre-loading model into memory..."
WARMUP_RESPONSE=$(curl -s --max-time 60 -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"stream\": false, \"options\": {\"num_predict\": 1}}" 2>/dev/null || echo "")

if [ -n "$WARMUP_RESPONSE" ] && echo "$WARMUP_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'message' in data else 1)" 2>/dev/null; then
    echo "   ✅ Model pre-loaded successfully!"
else
    ERROR=$(echo "$WARMUP_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Connection failed")
    echo "   ⚠️  Pre-load had an issue: $ERROR"
    echo "   💡 Model will load on first request"
fi
echo ""

# Step 5: Start API container
echo "5. Starting API container..."
docker-compose up -d api
echo "   ⏳ Waiting for API to start..."
sleep 5

# Wait for API to be ready
for i in {1..12}; do
    if curl -s --max-time 2 http://localhost:5001/health > /dev/null 2>&1; then
        echo "   ✅ API is ready"
        break
    fi
    if [ $i -eq 12 ]; then
        echo "   ⚠️  API is still starting (this is normal)"
    fi
    sleep 2
done
echo ""

# Step 6: Test LLM connection via API
echo "6. Testing LLM connection via API..."
sleep 3

TEST_RESPONSE=$(curl -s --max-time 15 http://localhost:5001/api/llm/test-connection 2>/dev/null || echo "")

if [ -n "$TEST_RESPONSE" ]; then
    STATUS=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status', 'unknown'))" 2>/dev/null || echo "unknown")
    
    if [ "$STATUS" = "success" ]; then
        PROVIDER=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('provider', 'unknown'))" 2>/dev/null || echo "unknown")
        MODEL_NAME=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('model', 'unknown'))" 2>/dev/null || echo "unknown")
        RESPONSE_TEXT=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('response', '')[:100])" 2>/dev/null || echo "")
        
        echo "   ✅ LLM connection successful!"
        echo "   Provider: $PROVIDER"
        echo "   Model: $MODEL_NAME"
        echo "   Test response: $RESPONSE_TEXT"
    else
        ERROR=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
        echo "   ❌ LLM test failed: $ERROR"
        echo "   💡 The model may still be loading. Wait a moment and try again."
    fi
else
    echo "   ⚠️  Could not test LLM (API may still be starting)"
    echo "   💡 Try again in a moment: curl http://localhost:5001/api/llm/test-connection"
fi
echo ""

# Step 7: Test a real NPC conversation query
echo "7. Testing NPC conversation query..."
sleep 2

NPC_TEST=$(curl -s --max-time 30 -X POST http://localhost:5001/api/npcs/skeleton-1/interact \
  -H "Content-Type: application/json" \
  -d '{"device_uuid": "test-device", "message": "Where is the treasure?", "npc_name": "Captain Bones", "npc_type": "skeleton", "is_skeleton": true}' 2>/dev/null || echo "")

if [ -n "$NPC_TEST" ]; then
    NPC_STATUS=$(echo "$NPC_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print('success' if 'response' in data else 'error')" 2>/dev/null || echo "unknown")
    
    if [ "$NPC_STATUS" = "success" ]; then
        NPC_RESPONSE=$(echo "$NPC_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('response', '')[:150])" 2>/dev/null || echo "")
        echo "   ✅ NPC conversation test successful!"
        echo "   Response: $NPC_RESPONSE"
    else
        ERROR=$(echo "$NPC_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
        echo "   ⚠️  NPC test had issues: $ERROR"
    fi
else
    echo "   ⚠️  Could not test NPC conversation (may still be loading)"
fi
echo ""

echo "=================================="
echo "✅ Setup and testing complete!"
echo ""
echo "Summary:"
echo "  - Model: $MODEL (350M parameters, ~500MB)"
echo "  - Container: cache-raiders-ollama"
echo "  - API: http://localhost:5001"
echo ""
echo "Quick test commands:"
echo "  - Test LLM: curl http://localhost:5001/api/llm/test-connection"
echo "  - Test NPC: curl -X POST http://localhost:5001/api/npcs/skeleton-1/interact \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"device_uuid\": \"test\", \"message\": \"Hi\", \"npc_name\": \"Captain Bones\", \"npc_type\": \"skeleton\", \"is_skeleton\": true}'"
echo ""
echo "View logs:"
echo "  - Ollama: docker-compose logs -f ollama"
echo "  - API: docker-compose logs -f api"
echo ""

