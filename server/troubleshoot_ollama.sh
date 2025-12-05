#!/bin/bash
# Comprehensive troubleshooting script for Ollama container and API connection

set -e

echo "🔧 Ollama Troubleshooting Script"
echo "=================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check Docker
echo "1. Checking Docker..."
if ! docker info > /dev/null 2>&1; then
    echo -e "   ${RED}❌ Docker is not running!${NC}"
    echo "   💡 Please start Docker Desktop first"
    exit 1
fi
echo -e "   ${GREEN}✅ Docker is running${NC}"
echo ""

# Check if containers exist
echo "2. Checking containers..."
cd "$(dirname "$0")"

OLLAMA_CONTAINER="cache-raiders-ollama"
API_CONTAINER=$(docker ps --filter "name=api" --format "{{.Names}}" | head -1)

if [ -z "$API_CONTAINER" ]; then
    API_CONTAINER=$(docker ps --format "{{.Names}}" | grep -i "cache-raiders.*api\|api.*cache" | head -1)
fi

# Check Ollama container
if ! docker ps --format "{{.Names}}" | grep -q "^${OLLAMA_CONTAINER}$"; then
    echo -e "   ${YELLOW}⚠️  Ollama container not running${NC}"
    echo "   💡 Starting containers..."
    docker-compose up -d ollama
    echo "   ⏳ Waiting for Ollama to start..."
    sleep 10
fi

if docker ps --format "{{.Names}}" | grep -q "^${OLLAMA_CONTAINER}$"; then
    echo -e "   ${GREEN}✅ Ollama container is running${NC}"
    OLLAMA_STATUS=$(docker inspect -f '{{.State.Status}}' "$OLLAMA_CONTAINER" 2>/dev/null)
    echo "   Status: $OLLAMA_STATUS"
else
    echo -e "   ${RED}❌ Ollama container failed to start${NC}"
    echo "   Check logs: docker-compose logs ollama"
    exit 1
fi
echo ""

# Check API container
if [ -n "$API_CONTAINER" ] && docker ps --format "{{.Names}}" | grep -q "^${API_CONTAINER}$"; then
    echo -e "   ${GREEN}✅ API container is running: $API_CONTAINER${NC}"
else
    echo -e "   ${YELLOW}⚠️  API container not running (this is okay if testing Ollama only)${NC}"
fi
echo ""

# Test Ollama API from host
echo "3. Testing Ollama API from host (localhost:11434)..."
if curl -s --max-time 5 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo -e "   ${GREEN}✅ Ollama API is accessible on localhost:11434${NC}"
    
    # Get available models
    MODELS_JSON=$(curl -s http://localhost:11434/api/tags)
    MODEL_COUNT=$(echo "$MODELS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('models', [])))" 2>/dev/null || echo "0")
    
    if [ "$MODEL_COUNT" -gt 0 ]; then
        echo "   📦 Available models:"
        echo "$MODELS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); [print(f'      - {m[\"name\"]}') for m in data.get('models', [])]" 2>/dev/null || echo "      (Unable to parse)"
    else
        echo -e "   ${YELLOW}⚠️  No models found in Ollama${NC}"
    fi
else
    echo -e "   ${RED}❌ Cannot connect to Ollama on localhost:11434${NC}"
    echo "   Check if port is exposed: docker port $OLLAMA_CONTAINER"
    exit 1
fi
echo ""

# Test from API container (if running)
if [ -n "$API_CONTAINER" ] && docker ps --format "{{.Names}}" | grep -q "^${API_CONTAINER}$"; then
    echo "4. Testing Ollama connection from API container..."
    
    # Check if curl is available in API container
    if docker exec "$API_CONTAINER" which curl > /dev/null 2>&1; then
        if docker exec "$API_CONTAINER" curl -s --max-time 5 http://ollama:11434/api/tags > /dev/null 2>&1; then
            echo -e "   ${GREEN}✅ API container can reach Ollama via container name (ollama:11434)${NC}"
        else
            echo -e "   ${RED}❌ API container cannot reach Ollama${NC}"
            echo "   Check network connectivity between containers"
        fi
    else
        echo -e "   ${YELLOW}⚠️  curl not available in API container (testing with Python instead)${NC}"
        if docker exec "$API_CONTAINER" python3 -c "import requests; requests.get('http://ollama:11434/api/tags', timeout=5)" > /dev/null 2>&1; then
            echo -e "   ${GREEN}✅ API container can reach Ollama via Python requests${NC}"
        else
            echo -e "   ${RED}❌ API container cannot reach Ollama${NC}"
        fi
    fi
    echo ""
    
    # Check configured model
    echo "5. Checking configured model..."
    CONFIGURED_MODEL=$(docker exec "$API_CONTAINER" printenv LLM_MODEL 2>/dev/null || echo "")
    
    if [ -z "$CONFIGURED_MODEL" ]; then
        # Try docker inspect
        if command -v jq > /dev/null 2>&1; then
            CONFIGURED_MODEL=$(docker inspect "$API_CONTAINER" 2>/dev/null | jq -r '.[0].Config.Env[] | select(startswith("LLM_MODEL=")) | sub("LLM_MODEL="; "")' 2>/dev/null || echo "")
        fi
    fi
    
    if [ -z "$CONFIGURED_MODEL" ]; then
        # Check docker-compose.yml
        if [ -f "docker-compose.yml" ]; then
            CONFIGURED_MODEL=$(grep "LLM_MODEL" docker-compose.yml | head -1 | sed 's/.*LLM_MODEL=\([^ ]*\).*/\1/' | tr -d '"' || echo "")
        fi
    fi
    
    if [ -n "$CONFIGURED_MODEL" ]; then
        echo "   Configured model: $CONFIGURED_MODEL"
        
        # Check if model is available
        MODEL_AVAILABLE=$(echo "$MODELS_JSON" | python3 -c "import sys, json; model=sys.argv[1]; data=json.load(sys.stdin); models=[m['name'] for m in data.get('models', [])]; print('yes' if model in models or any(model in m for m in models) else 'no')" "$CONFIGURED_MODEL" 2>/dev/null || echo "unknown")
        
        if [ "$MODEL_AVAILABLE" = "yes" ]; then
            echo -e "   ${GREEN}✅ Model '$CONFIGURED_MODEL' is available in Ollama${NC}"
        else
            echo -e "   ${YELLOW}⚠️  Model '$CONFIGURED_MODEL' is configured but not found in Ollama${NC}"
            echo "   💡 Pull the model: docker exec -it $OLLAMA_CONTAINER ollama pull $CONFIGURED_MODEL"
        fi
    else
        echo -e "   ${YELLOW}⚠️  No model configured (will use default)${NC}"
    fi
    echo ""
fi

# Test chat API with configured model
echo "6. Testing chat API..."
CONFIGURED_MODEL=${CONFIGURED_MODEL:-"llama3.2:1b"}

echo "   Testing with model: $CONFIGURED_MODEL"
TEST_RESPONSE=$(curl -s --max-time 30 -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$CONFIGURED_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say Ahoy in one word\"}], \"stream\": false}" 2>/dev/null || echo "")

if [ -n "$TEST_RESPONSE" ] && echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'message' in data else 1)" 2>/dev/null; then
    echo -e "   ${GREEN}✅ Chat API is working${NC}"
    CONTENT=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('message', {}).get('content', '')[:50])" 2>/dev/null || echo "Response received")
    echo "   📝 Response: $CONTENT..."
else
    ERROR_MSG=$(echo "$TEST_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Connection failed")
    echo -e "   ${RED}❌ Chat test failed: $ERROR_MSG${NC}"
    
    if echo "$ERROR_MSG" | grep -qi "model.*not found\|model.*does not exist"; then
        echo "   💡 Model not installed. Pull it:"
        echo "      docker exec -it $OLLAMA_CONTAINER ollama pull $CONFIGURED_MODEL"
    fi
fi
echo ""

# Test API endpoint (if API container is running)
if [ -n "$API_CONTAINER" ] && docker ps --format "{{.Names}}" | grep -q "^${API_CONTAINER}$"; then
    echo "7. Testing API server LLM endpoint..."
    
    # Wait a bit for API to be ready
    sleep 2
    
    if curl -s --max-time 10 http://localhost:5001/api/llm/test-connection > /dev/null 2>&1; then
        API_RESPONSE=$(curl -s --max-time 10 http://localhost:5001/api/llm/test-connection)
        STATUS=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status', 'unknown'))" 2>/dev/null || echo "unknown")
        
        if [ "$STATUS" = "success" ]; then
            echo -e "   ${GREEN}✅ API LLM test endpoint is working${NC}"
            PROVIDER=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('provider', 'unknown'))" 2>/dev/null || echo "unknown")
            MODEL=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('model', 'unknown'))" 2>/dev/null || echo "unknown")
            echo "   Provider: $PROVIDER, Model: $MODEL"
        else
            ERROR=$(echo "$API_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
            echo -e "   ${RED}❌ API LLM test failed: $ERROR${NC}"
        fi
    else
        echo -e "   ${YELLOW}⚠️  API server not responding (may still be starting)${NC}"
        echo "   Check logs: docker-compose logs api"
    fi
    echo ""
fi

# Summary
echo "=================================="
echo "Summary"
echo "=================================="
echo ""

# Check if model needs to be pulled
if [ "$MODEL_AVAILABLE" != "yes" ] && [ -n "$CONFIGURED_MODEL" ]; then
    echo -e "${YELLOW}⚠️  ACTION REQUIRED:${NC}"
    echo "   Pull the configured model:"
    echo "   docker exec -it $OLLAMA_CONTAINER ollama pull $CONFIGURED_MODEL"
    echo ""
fi

echo "Quick commands:"
echo "  - View Ollama logs: docker-compose logs -f ollama"
echo "  - View API logs: docker-compose logs -f api"
echo "  - Pull model: docker exec -it $OLLAMA_CONTAINER ollama pull $CONFIGURED_MODEL"
echo "  - Test API: curl http://localhost:5001/api/llm/test-connection"
echo "  - List models: docker exec $OLLAMA_CONTAINER ollama list"
echo ""

