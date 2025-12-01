#!/bin/bash
# Setup Colima (lightweight Docker alternative) and run containers

set -e

echo "🚀 Setting up Colima (Lightweight Docker Alternative)"
echo "====================================================="
echo ""

# Check if Colima is installed
if ! command -v colima &> /dev/null; then
    echo "📥 Colima is not installed. Installing via Homebrew..."
    if ! command -v brew &> /dev/null; then
        echo "❌ Homebrew is not installed. Please install it first:"
        echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    brew install colima docker docker-compose
    echo "✅ Colima and Docker installed"
else
    echo "✅ Colima is already installed"
fi
echo ""

# Start Colima
echo "1. Starting Colima..."
if colima status 2>/dev/null | grep -q "Running"; then
    echo "   ✅ Colima is already running"
else
    echo "   🚀 Starting Colima (this may take a minute)..."
    colima start --cpu 2 --memory 4
    echo "   ✅ Colima started"
fi
echo ""

# Configure Docker to use Colima
echo "2. Configuring Docker to use Colima..."
export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
echo "   ✅ Docker configured"
echo ""

# Test Docker
echo "3. Testing Docker connection..."
if docker info > /dev/null 2>&1; then
    echo "   ✅ Docker is working with Colima"
else
    echo "   ❌ Docker connection failed"
    exit 1
fi
echo ""

echo "====================================================="
echo "✅ Colima is ready!"
echo ""
echo "Now you can run your Docker containers:"
echo "  cd server"
echo "  ./setup_and_test_granite.sh"
echo ""
echo "Colima uses much less resources than Docker Desktop!"
echo ""

