#!/bin/bash
# Ollama entrypoint script that pre-loads the model on container start

set -e

# Default model (can be overridden via environment variable)
MODEL=${OLLAMA_MODEL:-"granite4:350m"}

echo "🚀 Starting Ollama with auto-load for model: $MODEL"

# Start Ollama in the background
echo "📦 Starting Ollama server..."
# Explicitly export OLLAMA_HOST to ensure Ollama listens on 0.0.0.0
export OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"
echo "   Ollama will listen on: $OLLAMA_HOST"
/bin/ollama serve &

# Wait for Ollama to be ready
echo "⏳ Waiting for Ollama to be ready..."
for i in {1..60}; do
    # Use ollama list to check if server is ready (will fail if not ready)
    if /bin/ollama list > /dev/null 2>&1; then
        echo "✅ Ollama is ready!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "⚠️  Ollama took too long to start, continuing anyway..."
        break
    fi
    sleep 1
done

# Check if model is installed using ollama list
echo "🔍 Checking if model $MODEL is installed..."
MODEL_EXISTS="no"
if /bin/ollama list 2>/dev/null | grep -q "$MODEL"; then
    MODEL_EXISTS="yes"
fi

if [ "$MODEL_EXISTS" = "no" ]; then
    echo "📥 Model $MODEL not found. Pulling it now..."
    if /bin/ollama pull "$MODEL" 2>&1; then
        echo "✅ Model $MODEL pulled successfully!"
    else
        echo "⚠️  Failed to pull model $MODEL. It will be loaded on first request."
        echo "   You can manually pull it later with: docker exec cache-raiders-ollama ollama pull $MODEL"
    fi
else
    echo "✅ Model $MODEL is already installed"
fi

# Pre-load the model into memory using ollama run
echo "🔥 Pre-loading model $MODEL into memory..."
if echo "Hi" | /bin/ollama run "$MODEL" --verbose false > /dev/null 2>&1; then
    echo "✅ Model $MODEL pre-loaded and ready!"
else
    echo "⚠️  Pre-load had an issue, but Ollama is running. Model will load on first request."
fi

echo "🎉 Ollama is ready to serve requests!"
echo ""

# Keep the container running (Ollama is already running in background)
wait

