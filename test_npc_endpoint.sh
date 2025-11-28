#!/bin/bash

# Test script for NPC interaction endpoint
# This helps isolate whether the problem is in the app, server endpoint, or LLM API

# Default server URL (change if your server is on a different host/port)
SERVER_URL="${1:-http://localhost:5001}"

echo "🧪 Testing NPC Interaction Endpoint"
echo "===================================="
echo "Server URL: $SERVER_URL"
echo ""

# Test 1: Check if server is running
echo "📡 Test 1: Checking if server is running..."
HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "$SERVER_URL/health" 2>/dev/null)
if [ "$HEALTH_RESPONSE" = "200" ]; then
    echo "✅ Server is running"
else
    echo "❌ Server is not responding (HTTP $HEALTH_RESPONSE)"
    echo "   Make sure your Flask server is running: cd server && python app.py"
    exit 1
fi
echo ""

# Test 2: Check LLM service availability
echo "🤖 Test 2: Checking LLM service availability..."
LLM_TEST=$(curl -s "$SERVER_URL/api/llm/test-connection" 2>/dev/null)
if echo "$LLM_TEST" | grep -q '"status":"success"'; then
    echo "✅ LLM service is available"
    echo "   Response: $LLM_TEST"
else
    echo "⚠️  LLM service may not be available"
    echo "   Response: $LLM_TEST"
    echo "   This might be okay if you're using Ollama (it will test on first request)"
fi
echo ""

# Test 3: Test NPC interaction endpoint
echo "💬 Test 3: Testing NPC interaction endpoint..."
echo "   Endpoint: POST $SERVER_URL/api/npcs/skeleton-1/interact"
echo ""

REQUEST_BODY='{
  "device_uuid": "test-device-123",
  "message": "Where is the treasure?",
  "npc_name": "Captain Bones",
  "npc_type": "skeleton",
  "is_skeleton": true
}'

echo "   Request body:"
echo "$REQUEST_BODY" | python3 -m json.tool 2>/dev/null || echo "$REQUEST_BODY"
echo ""

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$REQUEST_BODY" \
  "$SERVER_URL/api/npcs/skeleton-1/interact" 2>/dev/null)

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')

echo "   Response (HTTP $HTTP_STATUS):"
if command -v python3 &> /dev/null && echo "$RESPONSE_BODY" | python3 -m json.tool 2>/dev/null; then
    # Already formatted by python
    :
else
    echo "$RESPONSE_BODY"
fi
echo ""

# Analyze results
if [ "$HTTP_STATUS" = "200" ]; then
    if echo "$RESPONSE_BODY" | grep -q '"response"'; then
        RESPONSE_TEXT=$(echo "$RESPONSE_BODY" | grep -o '"response":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$RESPONSE_TEXT" ] && [ "$RESPONSE_TEXT" != "Error"* ]; then
            echo "✅ SUCCESS: Endpoint is working correctly!"
            echo "   LLM Response: $RESPONSE_TEXT"
            echo ""
            echo "💡 If the app still doesn't work, the problem is likely:"
            echo "   - Network connectivity (app can't reach server)"
            echo "   - Wrong baseURL in app settings"
            echo "   - iOS app code issue"
        else
            echo "⚠️  Endpoint responded but LLM returned an error"
            echo "   Check LLM service configuration (Ollama running? OpenAI key set?)"
        fi
    else
        echo "⚠️  Endpoint responded but response format is unexpected"
    fi
elif [ "$HTTP_STATUS" = "503" ]; then
    echo "❌ LLM service not available (503)"
    echo "   Check server logs for LLM initialization errors"
elif [ "$HTTP_STATUS" = "400" ]; then
    echo "❌ Bad request (400)"
    echo "   Check request format"
elif [ "$HTTP_STATUS" = "500" ]; then
    echo "❌ Server error (500)"
    echo "   Check server logs for error details"
    echo "   Response: $RESPONSE_BODY"
else
    echo "❌ Unexpected HTTP status: $HTTP_STATUS"
fi

echo ""
echo "===================================="
echo "Test complete!"

