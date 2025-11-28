#!/bin/bash
# Quick start script for CacheRaiders server with LLM support

echo "🚀 Starting CacheRaiders Server with LLM Integration..."
echo ""

# Check if we're in the right directory
if [ ! -f "app.py" ]; then
    echo "❌ Error: app.py not found!"
    echo "   Make sure you're in the server directory"
    exit 1
fi

# Check for .env file
if [ ! -f ".env" ]; then
    echo "⚠️  Warning: .env file not found!"
    echo "   Create server/.env with your OPENAI_API_KEY"
    exit 1
fi

# Check Python version
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: python3 not found!"
    exit 1
fi

# Check if openai is installed
if ! python3 -c "import openai" 2>/dev/null; then
    echo "⚠️  Installing dependencies..."
    pip install -r requirements.txt
fi

# Start the server
echo "✅ Starting server..."
echo ""
python3 app.py


