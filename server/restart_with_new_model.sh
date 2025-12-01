#!/bin/bash
# Restart containers with new model configuration

set -e

echo "🔄 Restarting containers with llama3.2:1b"
echo "=========================================="
echo ""

cd "$(dirname "$0")"

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running!"
    exit 1
fi

# Stop containers
echo "1. Stopping containers..."
docker-compose down
echo "   ✅ Containers stopped"
echo ""

# Start Ollama first
echo "2. Starting Ollama container..."
docker-compose up -d ollama
echo "   ⏳ Waiting for Ollama to start and load model (this may take 1-2 minutes)..."
sleep 15

# Check Ollama status
for i in {1..12}; do
    if docker exec cache-raiders-ollama ollama list > /dev/null 2>&1; then
        echo "   ✅ Ollama is ready"
        break
    fi
    if [ $i -eq 12 ]; then
        echo "   ⚠️  Ollama is still starting (this is normal, it's loading the model)"
    fi
    sleep 5
done
echo ""

# Check if model is being loaded
echo "3. Checking model status..."
MODEL_STATUS=$(docker exec cache-raiders-ollama ollama list 2>/dev/null | grep -c "llama3.2:1b" || echo "0")
if [ "$MODEL_STATUS" -gt 0 ]; then
    echo "   ✅ Model llama3.2:1b is installed"
else
    echo "   ⏳ Model is still being pulled/loaded (this is normal on first run)"
fi
echo ""

# Start API container
echo "4. Starting API container..."
docker-compose up -d api
echo "   ⏳ Waiting for API to start..."
sleep 5
echo ""

# Test API connection
echo "5. Testing API connection..."
for i in {1..6}; do
    if curl -s --max-time 5 http://localhost:5001/health > /dev/null 2>&1; then
        echo "   ✅ API is ready"
        break
    fi
    if [ $i -eq 6 ]; then
        echo "   ⚠️  API is still starting"
    fi
    sleep 2
done
echo ""

# Test LLM connection
echo "6. Testing LLM connection..."
sleep 3
LLM_TEST=$(curl -s --max-time 10 http://localhost:5001/api/llm/test-connection 2>/dev/null || echo "")
if [ -n "$LLM_TEST" ]; then
    STATUS=$(echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('status', 'unknown'))" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "success" ]; then
        PROVIDER=$(echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('provider', 'unknown'))" 2>/dev/null || echo "unknown")
        MODEL=$(echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('model', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "   ✅ LLM is working!"
        echo "   Provider: $PROVIDER, Model: $MODEL"
    else
        ERROR=$(echo "$LLM_TEST" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('error', 'Unknown error'))" 2>/dev/null || echo "Unknown error")
        echo "   ⚠️  LLM test had issues: $ERROR"
        echo "   💡 The model may still be loading. Wait a minute and try again."
    fi
else
    echo "   ⚠️  Could not test LLM (API may still be starting)"
fi
echo ""

echo "=========================================="
echo "✅ Restart complete!"
echo ""
echo "The model is now set to: llama3.2:1b"
echo ""
echo "If you see timeout errors, the model is still loading."
echo "Wait 1-2 minutes and check again:"
echo "  curl http://localhost:5001/api/llm/test-connection"
echo ""

