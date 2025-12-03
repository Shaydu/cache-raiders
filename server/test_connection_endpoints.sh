#!/bin/bash
# Test script to verify server connectivity on both IPs
# Tests the Colima VM IP and the WiFi IP for iOS devices

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COLIMA_IP="192.168.64.3"
WIFI_IP="${HOST_IP:-10.0.0.201}"
PORT="5001"
TIMEOUT=5

echo "════════════════════════════════════════════════════════════════"
echo "🧪 Cache Raiders Server Connection Test"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Test counter
PASSED=0
FAILED=0

test_endpoint() {
    local name="$1"
    local url="$2"
    local expected_status="${3:-200}"
    
    echo -n "Testing $name... "
    
    response=$(curl -s -w "\n%{http_code}" --connect-timeout $TIMEOUT "$url" 2>/dev/null || echo -e "\n000")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -eq "$expected_status" ]; then
        echo -e "${GREEN}✓ PASS${NC} (HTTP $http_code)"
        if [ -n "$body" ]; then
            echo "  Response: $(echo "$body" | head -c 100)..."
        fi
        ((PASSED++))
        return 0
    elif [ "$http_code" -eq "000" ]; then
        echo -e "${RED}✗ FAIL${NC} (Connection timeout or refused)"
        ((FAILED++))
        return 1
    else
        echo -e "${RED}✗ FAIL${NC} (HTTP $http_code, expected $expected_status)"
        if [ -n "$body" ]; then
            echo "  Response: $(echo "$body" | head -c 100)..."
        fi
        ((FAILED++))
        return 1
    fi
}

# Section 1: Colima VM IP Tests
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📍 Testing Colima VM IP: $COLIMA_IP:$PORT${NC}"
echo -e "${BLUE}   (Used for local Mac access to admin panel)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

test_endpoint "Health Check" "http://$COLIMA_IP:$PORT/health"
test_endpoint "Server Info" "http://$COLIMA_IP:$PORT/api/server-info"
test_endpoint "Admin Panel" "http://$COLIMA_IP:$PORT/admin"
test_endpoint "Get Objects API" "http://$COLIMA_IP:$PORT/api/objects"
test_endpoint "Get Stats API" "http://$COLIMA_IP:$PORT/api/stats"
test_endpoint "Connection Test" "http://$COLIMA_IP:$PORT/api/debug/connection-test"

echo ""

# Section 2: WiFi IP Tests (for iOS devices)
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📱 Testing WiFi IP: $WIFI_IP:$PORT${NC}"
echo -e "${BLUE}   (Used by iOS devices - shown in QR code)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

test_endpoint "Health Check" "http://$WIFI_IP:$PORT/health"
test_endpoint "Server Info" "http://$WIFI_IP:$PORT/api/server-info"
test_endpoint "Admin Panel" "http://$WIFI_IP:$PORT/admin"
test_endpoint "Get Objects API" "http://$WIFI_IP:$PORT/api/objects"
test_endpoint "Get Stats API" "http://$WIFI_IP:$PORT/api/stats"
test_endpoint "Connection Test" "http://$WIFI_IP:$PORT/api/debug/connection-test"

echo ""

# Section 3: Port Forwarding Check
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🔌 Port Forwarding Status${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo "Checking processes listening on port $PORT:"
if lsof -i :$PORT 2>/dev/null | grep -q "LISTEN"; then
    echo -e "${GREEN}✓${NC} Port $PORT is active"
    lsof -i :$PORT 2>/dev/null | grep "LISTEN" | while read line; do
        echo "  $line"
    done
else
    echo -e "${RED}✗${NC} No process listening on port $PORT"
    ((FAILED++))
fi

echo ""

# Section 4: Docker Container Status
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🐳 Docker Container Status${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if command -v docker &> /dev/null; then
    if docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -q "cache-raiders"; then
        echo -e "${GREEN}✓${NC} Docker containers are running:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "(NAMES|cache-raiders)"
    else
        echo -e "${YELLOW}⚠${NC} No Cache Raiders containers found"
    fi
else
    echo -e "${YELLOW}⚠${NC} Docker command not available (may need to run outside sandbox)"
fi

echo ""

# Section 5: Network Configuration
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🌐 Network Configuration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo "Environment Variables:"
echo "  HOST_IP: ${HOST_IP:-<not set>}"
echo ""

echo "Detected Network Interfaces:"
if command -v ifconfig &> /dev/null; then
    ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | grep -A1 "^en" | grep -v "127.0.0.1" | head -10 || echo "  (ifconfig requires elevated permissions)"
else
    echo "  ifconfig not available"
fi

echo ""

# Section 6: iOS App Configuration
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📱 iOS App Configuration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo "To connect your iOS app:"
echo "  1. Open Settings in the Cache Raiders app"
echo "  2. Enter this URL: ${GREEN}http://$WIFI_IP:$PORT${NC}"
echo "  3. Or scan the QR code from: ${GREEN}http://$COLIMA_IP:$PORT/admin${NC}"
echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "📊 Test Summary"
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
else
    echo -e "${GREEN}Failed: $FAILED${NC}"
fi
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed! Server is accessible from both IPs.${NC}"
    echo ""
    echo "Next steps:"
    echo "  • iOS devices should use: http://$WIFI_IP:$PORT"
    echo "  • Admin panel accessible at: http://$COLIMA_IP:$PORT/admin"
    exit 0
else
    echo -e "${RED}❌ Some tests failed. Check the output above for details.${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Verify server is running: docker compose ps"
    echo "  2. Check port forwarding: lsof -i :$PORT"
    echo "  3. Verify HOST_IP is set: echo \$HOST_IP"
    echo "  4. Restart server: ./start-server.sh"
    exit 1
fi






