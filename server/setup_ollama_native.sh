#!/bin/bash
# Setup Ollama natively on macOS (no Docker needed)

set -e

echo "🚀 Setting up Ollama Native (No Docker)"
echo "======================================="
echo ""

MODEL="granite4:350m"

# Check if Ollama is installed
if ! command -v ollama &> /dev/null; then
    echo "📥 Ollama is not installed. Installing via Homebrew..."
    if ! command -v brew &> /dev/null; then
        echo "❌ Homebrew is not installed. Please install it first:"
        echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    brew install ollama
    echo "✅ Ollama installed"
else
    echo "✅ Ollama is already installed"
fi
echo ""

# Start Ollama service
echo "1. Starting Ollama service..."
if pgrep -x "ollama" > /dev/null; then
    echo "   ✅ Ollama is already running"
else
    echo "   🚀 Starting Ollama..."
    ollama serve > /dev/null 2>&1 &
    sleep 5
    echo "   ✅ Ollama started"
fi
echo ""

# Check if Ollama is accessible
echo "2. Checking Ollama API..."
for i in {1..10}; do
    if curl -s --max-time 2 http://localhost:11434/api/tags > /dev/null 2>&1; then
        echo "   ✅ Ollama API is ready"
        break
    fi
    if [ $i -eq 10 ]; then
        echo "   ❌ Ollama API not responding"
        exit 1
    fi
    sleep 1
done
echo ""

# Check if model is installed
echo "3. Checking for $MODEL model..."
MODEL_EXISTS=$(ollama list 2>/dev/null | grep -c "$MODEL" || echo "0")

if [ "$MODEL_EXISTS" -eq 0 ]; then
    echo "   📥 Pulling $MODEL (this may take a few minutes)..."
    ollama pull "$MODEL"
    echo "   ✅ Model $MODEL pulled successfully!"
else
    echo "   ✅ Model $MODEL is already installed"
fi
echo ""

# Pre-load the model
echo "4. Pre-loading model into memory..."
WARMUP_RESPONSE=$(curl -s --max-time 60 -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"stream\": false, \"options\": {\"num_predict\": 1}}" 2>/dev/null || echo "")

if [ -n "$WARMUP_RESPONSE" ] && echo "$WARMUP_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if 'message' in data else 1)" 2>/dev/null; then
    echo "   ✅ Model pre-loaded successfully!"
else
    echo "   ⚠️  Pre-load had an issue, but continuing..."
fi
echo ""

echo "======================================="
echo "✅ Ollama is ready!"
echo ""
echo "Model: $MODEL"
echo "API: http://localhost:11434"
echo ""
echo "Update your .env file to use:"
echo "  LLM_BASE_URL=http://localhost:11434"
echo "  LLM_MODEL=$MODEL"
echo ""
echo "Then start your API server normally (without Docker)"
echo ""

