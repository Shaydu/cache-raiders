#!/bin/bash
# Comprehensive script to show running containers and test their APIs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
OLLAMA_PORT=11434
API_PORT=5001
OLLAMA_CONTAINER="cache-raiders-ollama"
API_CONTAINER="cache-raiders-api"

echo "=========================================="
echo "🐳 CacheRaiders Container & API Test"
echo "=========================================="
echo ""

# Change to server directory
cd "$(dirname "$0")"

# ============================================
# 1. Show Running Containers
# ============================================
echo -e "${CYAN}1️⃣  Running Containers${NC}"
echo "----------------------------------------"

if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}❌ Docker is not running!${NC}"
    exit 1
fi

# List all cache-raiders related containers
echo "📦 CacheRaiders containers:"
docker ps --filter "name=cache-raiders" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "   No containers found"

echo ""
echo "📦 All running containers:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -20

echo ""

# ============================================
# 2. Test Ollama Container & API
# ============================================
echo -e "${CYAN}2️⃣  Ollama Container & API Tests${NC}"
echo "----------------------------------------"

OLLAMA_RUNNING=false
OLLAMA_HEALTHY=false
OLLAMA_API_WORKING=false
OLLAMA_MODEL_AVAILABLE=false

# Check if Ollama container is running
if docker ps --format "{{.Names}}" | grep -q "^${OLLAMA_CONTAINER}$"; then
    OLLAMA_RUNNING=true
    echo -e "${GREEN}✅ Ollama container is running${NC}"
    
    # Check health status
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$OLLAMA_CONTAINER" 2>/dev/null || echo "unknown")
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        OLLAMA_HEALTHY=true
        echo -e "${GREEN}✅ Ollama container is healthy${NC}"
    else
        echo -e "${YELLOW}⚠️  Ollama container health: $HEALTH_STATUS${NC}"
    fi
else
    echo -e "${RED}❌ Ollama container is not running${NC}"
    echo "   💡 Start it with: docker-compose up -d ollama"
fi

# Test Ollama API
echo ""
echo "🔍 Testing Ollama API (http://localhost:${OLLAMA_PORT})..."

if curl -s --max-time 5 "http://localhost:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1; then
    OLLAMA_API_WORKING=true
    echo -e "${GREEN}✅ Ollama API is accessible${NC}"
    
    # Get available models
    MODELS_JSON=$(curl -s "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null || echo "{}")
    MODEL_COUNT=$(echo "$MODELS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('models', [])))" 2>/dev/null || echo "0")
    
    if [ "$MODEL_COUNT" -gt 0 ]; then
        OLLAMA_MODEL_AVAILABLE=true
        echo -e "${GREEN}✅ Models available: $MODEL_COUNT${NC}"
        echo "   📦 Installed models:"
        echo "$MODELS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); [print(f'      - {m[\"name\"]} ({m.get(\"size\", 0) / 1024 / 1024 / 1024:.2f} GB)') for m in data.get('models', [])]" 2>/dev/null || echo "      (Unable to parse)"
    else
        echo -e "${YELLOW}⚠️  No models installed${NC}"
        echo "   💡 Pull a model: docker exec $OLLAMA_CONTAINER ollama pull granite4:350m"
    fi
else
    echo -e "${RED}❌ Ollama API is not accessible${NC}"
    echo "   💡 Check if port $OLLAMA_PORT is exposed and container is running"
fi

# Test Ollama chat API if model is available
if [ "$OLLAMA_MODEL_AVAILABLE" = true ]; then
    echo ""
    echo "💬 Testing Ollama chat API..."
    TEST_MODEL=$(echo "$MODELS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); models=data.get('models', []); print(models[0]['name'] if models else '')" 2>/dev/null || echo "")
    
    if [ -n "$TEST_MODEL" ]; then
        CHAT_RESPONSE=$(curl -s --max-time 30 -X POST "http://localhost:${OLLAMA_PORT}/api/chat" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$TEST_MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Say 'OK'\"}], \"stream\": false}" 2>/dev/null || echo "")
        
        if echo "$CHAT_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'message' in data else 1)" 2>/dev/null; then
            echo -e "${GREEN}✅ Ollama chat API is working${NC}"
        else
            echo -e "${YELLOW}⚠️  Ollama chat API test failed${NC}"
        fi
    fi
fi

echo ""

# ============================================
# 3. Test App API Container & Endpoints
# ============================================
echo -e "${CYAN}3️⃣  App API Container & Endpoints${NC}"
echo "----------------------------------------"

API_RUNNING=false
API_HEALTHY=false

# Check if API container is running
API_CONTAINER_NAME=$(docker ps --format "{{.Names}}" | grep -i "cache-raiders.*api\|api.*cache" | head -1 || echo "")
if [ -n "$API_CONTAINER_NAME" ]; then
    API_RUNNING=true
    echo -e "${GREEN}✅ API container is running: $API_CONTAINER_NAME${NC}"
    
    # Check health status if available
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$API_CONTAINER_NAME" 2>/dev/null || echo "unknown")
    if [ "$HEALTH_STATUS" = "healthy" ]; then
        API_HEALTHY=true
        echo -e "${GREEN}✅ API container is healthy${NC}"
    elif [ "$HEALTH_STATUS" != "unknown" ]; then
        echo -e "${YELLOW}⚠️  API container health: $HEALTH_STATUS${NC}"
    fi
else
    echo -e "${RED}❌ API container is not running${NC}"
    echo "   💡 Start it with: docker-compose up -d api"
fi

# Test App API endpoints
echo ""
echo "🔍 Testing App API (http://localhost:${API_PORT})..."

# Test health endpoint
echo ""
echo "   Testing /health..."
if HEALTH_RESPONSE=$(curl -s --max-time 5 "http://localhost:${API_PORT}/health" 2>/dev/null); then
    if echo "$HEALTH_RESPONSE" | grep -q "ok\|healthy\|status" 2>/dev/null; then
        echo -e "   ${GREEN}✅ /health endpoint: OK${NC}"
        echo "      Response: $HEALTH_RESPONSE"
    else
        echo -e "   ${YELLOW}⚠️  /health endpoint: Unexpected response${NC}"
        echo "      Response: $HEALTH_RESPONSE"
    fi
else
    echo -e "   ${RED}❌ /health endpoint: Not accessible${NC}"
fi

# Test server-info endpoint
echo ""
echo "   Testing /api/server-info..."
if SERVER_INFO=$(curl -s --max-time 5 "http://localhost:${API_PORT}/api/server-info" 2>/dev/null); then
    if echo "$SERVER_INFO" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'ip' in data or 'port' in data or 'version' in data else 1)" 2>/dev/null; then
        echo -e "   ${GREEN}✅ /api/server-info endpoint: OK${NC}"
        IP=$(echo "$SERVER_INFO" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('ip', 'unknown'))" 2>/dev/null || echo "unknown")
        PORT=$(echo "$SERVER_INFO" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('port', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "      IP: $IP, Port: $PORT"
    else
        echo -e "   ${YELLOW}⚠️  /api/server-info endpoint: Unexpected response${NC}"
    fi
else
    echo -e "   ${RED}❌ /api/server-info endpoint: Not accessible${NC}"
fi

# Test LLM test endpoint
echo ""
echo "   Testing /api/llm/test..."
if LLM_TEST=$(curl -s --max-time 10 "http://localhost:${API_PORT}/api/llm/test" 2>/dev/null); then
    if echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'status' in data or 'provider' in data else 1)" 2>/dev/null; then
        echo -e "   ${GREEN}✅ /api/llm/test endpoint: OK${NC}"
        PROVIDER=$(echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('provider', 'unknown'))" 2>/dev/null || echo "unknown")
        STATUS=$(echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "      Provider: $PROVIDER, Status: $STATUS"
    else
        echo -e "   ${YELLOW}⚠️  /api/llm/test endpoint: Unexpected response${NC}"
        echo "      Response: ${LLM_TEST:0:100}..."
    fi
else
    echo -e "   ${RED}❌ /api/llm/test endpoint: Not accessible${NC}"
fi

# Test LLM provider endpoint
echo ""
echo "   Testing /api/llm/provider..."
if LLM_PROVIDER=$(curl -s --max-time 5 "http://localhost:${API_PORT}/api/llm/provider" 2>/dev/null); then
    if echo "$LLM_PROVIDER" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'provider' in data or 'model' in data else 1)" 2>/dev/null; then
        echo -e "   ${GREEN}✅ /api/llm/provider endpoint: OK${NC}"
        PROVIDER=$(echo "$LLM_PROVIDER" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('provider', 'unknown'))" 2>/dev/null || echo "unknown")
        MODEL=$(echo "$LLM_PROVIDER" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('model', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "      Provider: $PROVIDER, Model: $MODEL"
    else
        echo -e "   ${YELLOW}⚠️  /api/llm/provider endpoint: Unexpected response${NC}"
    fi
else
    echo -e "   ${RED}❌ /api/llm/provider endpoint: Not accessible${NC}"
fi

# Test objects endpoint
echo ""
echo "   Testing /api/objects..."
if OBJECTS=$(curl -s --max-time 5 "http://localhost:${API_PORT}/api/objects" 2>/dev/null); then
    if echo "$OBJECTS" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if isinstance(data, list) or 'objects' in data else 1)" 2>/dev/null; then
        OBJECT_COUNT=$(echo "$OBJECTS" | python3 -c "import sys, json; data=json.load(sys.stdin); obj_list = data if isinstance(data, list) else data.get('objects', []); print(len(obj_list))" 2>/dev/null || echo "0")
        echo -e "   ${GREEN}✅ /api/objects endpoint: OK${NC}"
        echo "      Objects count: $OBJECT_COUNT"
    else
        echo -e "   ${YELLOW}⚠️  /api/objects endpoint: Unexpected response${NC}"
    fi
else
    echo -e "   ${RED}❌ /api/objects endpoint: Not accessible${NC}"
fi

# Test stats endpoint
echo ""
echo "   Testing /api/stats..."
if STATS=$(curl -s --max-time 5 "http://localhost:${API_PORT}/api/stats" 2>/dev/null); then
    if echo "$STATS" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0)" 2>/dev/null; then
        echo -e "   ${GREEN}✅ /api/stats endpoint: OK${NC}"
    else
        echo -e "   ${YELLOW}⚠️  /api/stats endpoint: Unexpected response${NC}"
    fi
else
    echo -e "   ${RED}❌ /api/stats endpoint: Not accessible${NC}"
fi

echo ""

# ============================================
# 4. Summary
# ============================================
echo -e "${CYAN}4️⃣  Summary${NC}"
echo "----------------------------------------"
echo ""

# Ollama status
if [ "$OLLAMA_RUNNING" = true ] && [ "$OLLAMA_API_WORKING" = true ] && [ "$OLLAMA_MODEL_AVAILABLE" = true ]; then
    echo -e "${GREEN}✅ Ollama: Fully operational${NC}"
elif [ "$OLLAMA_RUNNING" = true ] && [ "$OLLAMA_API_WORKING" = true ]; then
    echo -e "${YELLOW}⚠️  Ollama: Running but no models installed${NC}"
elif [ "$OLLAMA_RUNNING" = true ]; then
    echo -e "${YELLOW}⚠️  Ollama: Container running but API not accessible${NC}"
else
    echo -e "${RED}❌ Ollama: Not running${NC}"
fi

# API status
if [ "$API_RUNNING" = true ]; then
    # Test if at least one endpoint works
    if curl -s --max-time 2 "http://localhost:${API_PORT}/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ App API: Running and accessible${NC}"
    else
        echo -e "${YELLOW}⚠️  App API: Container running but endpoints not accessible${NC}"
    fi
else
    echo -e "${RED}❌ App API: Not running${NC}"
fi

echo ""
echo "=========================================="
echo "📋 Quick Commands:"
echo "=========================================="
echo "  View Ollama logs:    docker-compose logs -f ollama"
echo "  View API logs:       docker-compose logs -f api"
echo "  Restart containers: docker-compose restart"
echo "  Start containers:   docker-compose up -d"
echo "  Stop containers:    docker-compose down"
echo "  Pull Ollama model:  docker exec $OLLAMA_CONTAINER ollama pull granite4:350m"
echo ""
echo "=========================================="

