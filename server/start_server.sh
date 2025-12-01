#!/bin/bash
# Quick start script for CacheRaiders server with LLM support
# Uses Docker Compose to run both the API server and Ollama in containers
# Automatically starts Docker Desktop if not running

echo "🚀 Starting CacheRaiders Server with Docker Compose..."
echo ""

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found!"
    echo "   Make sure you're in the server directory"
    exit 1
fi

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null && ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker not found!"
    echo "   Install Docker Desktop from https://www.docker.com/products/docker-desktop"
    exit 1
fi

# Use docker compose (newer) or docker-compose (older)
if command -v docker &> /dev/null && docker compose version &> /dev/null 2>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo "❌ Error: docker compose or docker-compose not found!"
    exit 1
fi

# Function to check if Docker is running
check_docker() {
    docker ps >/dev/null 2>&1
}

# Check if Docker Desktop is running
echo "🔍 Checking Docker Desktop status..."
if ! check_docker; then
    echo "⚠️  Docker Desktop is not running. Starting it now..."
    
    # Try to start Docker Desktop (macOS)
    if [ -d "/Applications/Docker.app" ]; then
        open -a Docker
        echo "⏳ Waiting for Docker Desktop to start (this may take 30-60 seconds)..."
        
        # Wait for Docker to be ready (max 2 minutes)
        MAX_WAIT=120
        ELAPSED=0
        while [ $ELAPSED -lt $MAX_WAIT ]; do
            if check_docker; then
                echo "✅ Docker Desktop is ready!"
                break
            fi
            sleep 2
            ELAPSED=$((ELAPSED + 2))
            if [ $((ELAPSED % 10)) -eq 0 ]; then
                echo "   Still waiting... (${ELAPSED}s/${MAX_WAIT}s)"
            fi
        done
        
        if ! check_docker; then
            echo "❌ Docker Desktop failed to start within ${MAX_WAIT} seconds"
            echo "   Please start Docker Desktop manually and try again"
            exit 1
        fi
    else
        echo "❌ Docker Desktop not found in Applications"
        echo "   Please install Docker Desktop from https://www.docker.com/products/docker-desktop"
        exit 1
    fi
else
    echo "✅ Docker Desktop is running"
fi

# Stop any locally running Python server that might conflict
echo "🛑 Stopping any locally running Python server..."
pkill -f "python.*app.py" 2>/dev/null
sleep 2

# Check for .env file and update it for containerized setup
if [ ! -f ".env" ]; then
    echo "⚠️  Warning: .env file not found!"
    echo "   Creating a basic .env file for containerized setup..."
    echo "# LLM Configuration" > .env
    echo "# Note: LLM_PROVIDER and LLM_BASE_URL are set by docker-compose.yml" >> .env
    echo "# When running in Docker, these will be overridden by container environment variables" >> .env
    echo "LLM_PROVIDER=ollama" >> .env
    echo "" >> .env
    echo "✅ Created .env file"
    echo ""
else
    # Update .env to ensure it doesn't conflict with Docker settings
    # Remove LLM_BASE_URL if it's set to localhost (Docker will set it to http://ollama:11434)
    if grep -q "LLM_BASE_URL.*localhost" .env 2>/dev/null; then
        echo "⚠️  Updating .env file: Removing localhost LLM_BASE_URL (Docker will use container name)"
        sed -i.bak '/LLM_BASE_URL.*localhost/d' .env
    fi
    # Ensure LLM_PROVIDER is set to ollama for containerized setup
    if ! grep -q "LLM_PROVIDER=ollama" .env 2>/dev/null; then
        echo "⚠️  Updating .env file: Setting LLM_PROVIDER=ollama for containerized setup"
        # Remove old LLM_PROVIDER line if exists
        sed -i.bak '/^LLM_PROVIDER=/d' .env
        echo "LLM_PROVIDER=ollama" >> .env
    fi
fi

# Start services with Docker Compose
echo ""
echo "🐳 Starting Docker containers..."
echo "   - API server will run on http://localhost:5001"
echo "   - Ollama will run in container (accessible at http://ollama:11434 from API container)"
echo "   - Admin panel: http://localhost:5001/admin"
echo ""

$DOCKER_COMPOSE_CMD up -d --build

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Containers started successfully!"
    echo ""
    
    # Wait a moment for containers to be ready
    echo "⏳ Waiting for services to be ready..."
    sleep 5
    
    # Check if Ollama container is healthy
    echo "🔍 Checking Ollama container status..."
    if docker ps | grep -q cache-raiders-ollama; then
        echo "✅ Ollama container is running"
        
        # Wait a bit more for Ollama to fully start
        sleep 3
        
        # Check if Ollama has any models, if not, suggest pulling one
        echo "🔍 Checking Ollama models..."
        MODELS=$(docker exec cache-raiders-ollama ollama list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if [ "$MODELS" -eq 0 ] || [ -z "$MODELS" ]; then
            echo "⚠️  No models found in Ollama container"
            echo "   Pulling default model: llama3.2:1b (very small and fast)"
            docker exec cache-raiders-ollama ollama pull llama3.2:1b
            if [ $? -eq 0 ]; then
                echo "✅ Model llama3.2:1b pulled successfully!"
            else
                echo "⚠️  Failed to pull model. You can pull it manually later:"
                echo "   docker exec -it cache-raiders-ollama ollama pull llama3.2:1b"
            fi
        else
            echo "✅ Found $MODELS model(s) in Ollama"
        fi
    else
        echo "⚠️  Ollama container not found. Check logs: $DOCKER_COMPOSE_CMD logs ollama"
    fi
    
    # Check API container
    echo "🔍 Checking API container status..."
    if docker ps | grep -q cache-raiders-api; then
        echo "✅ API container is running"
    else
        # Check if it's named differently
        API_CONTAINER=$(docker ps --format "{{.Names}}" | grep -i api | head -1)
        if [ -n "$API_CONTAINER" ]; then
            echo "✅ API container is running (named: $API_CONTAINER)"
        else
            echo "⚠️  API container not found. Check logs: $DOCKER_COMPOSE_CMD logs api"
        fi
    fi
    
    echo ""
    echo "📊 View logs:"
    echo "   $DOCKER_COMPOSE_CMD logs -f api"
    echo ""
    echo "📊 View Ollama logs:"
    echo "   $DOCKER_COMPOSE_CMD logs -f ollama"
    echo ""
    echo "🛑 Stop services:"
    echo "   $DOCKER_COMPOSE_CMD down"
    echo ""
    echo "🔄 Restart services:"
    echo "   $DOCKER_COMPOSE_CMD restart"
    echo ""
    echo "🌐 Access admin panel:"
    echo "   http://localhost:5001/admin"
    echo ""
    echo "💡 Note: The API connects to Ollama at http://ollama:11434 (container name)"
    echo "   This is set automatically by docker-compose.yml"
    echo ""
else
    echo "❌ Failed to start services. Check the error messages above."
    exit 1
fi
