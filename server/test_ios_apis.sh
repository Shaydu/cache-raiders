#!/bin/bash

# Test script for all iOS app API endpoints
# Usage: ./test_ios_apis.sh

BASE_URL="http://localhost:5001"
TEST_USER_ID="test-user-$(date +%s)"
TEST_OBJECT_ID="test-obj-$(date +%s)"

echo "🧪 Testing iOS App API Endpoints"
echo "=================================="
echo "Base URL: $BASE_URL"
echo "Test User ID: $TEST_USER_ID"
echo "Test Object ID: $TEST_OBJECT_ID"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
PASSED=0
FAILED=0

test_endpoint() {
    local name="$1"
    local method="$2"
    local endpoint="$3"
    local data="$4"
    local expected_status="${5:-200}"
    
    echo -n "Testing $name... "
    
    if [ -z "$data" ]; then
        response=$(curl -s -w "\n%{http_code}" -X "$method" "$BASE_URL$endpoint" 2>/dev/null)
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" "$BASE_URL$endpoint" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null)
    fi
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" -eq "$expected_status" ]; then
        echo -e "${GREEN}✓ PASS${NC} (HTTP $http_code)"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC} (HTTP $http_code, expected $expected_status)"
        echo "  Response: $body"
        ((FAILED++))
        return 1
    fi
}

# 1. Health Check
echo "1. Health Check"
test_endpoint "GET /health" "GET" "/health"
echo ""

# 2. Get all objects (no filters)
echo "2. Get Objects"
test_endpoint "GET /api/objects (no filters)" "GET" "/api/objects"
echo ""

# 3. Get objects with location filter
echo "3. Get Objects with Location Filter"
test_endpoint "GET /api/objects (with lat/lon)" "GET" "/api/objects?latitude=40.0758&longitude=-105.3008&radius=1000&include_found=false"
echo ""

# 4. Create a test object
echo "4. Create Object"
CREATE_DATA="{\"id\":\"$TEST_OBJECT_ID\",\"name\":\"Test Object\",\"type\":\"Treasure Chest\",\"latitude\":40.0758,\"longitude\":-105.3008,\"radius\":5.0,\"created_by\":\"$TEST_USER_ID\"}"
test_endpoint "POST /api/objects" "POST" "/api/objects" "$CREATE_DATA" "201"
echo ""

# 5. Get specific object
echo "5. Get Specific Object"
test_endpoint "GET /api/objects/{id}" "GET" "/api/objects/$TEST_OBJECT_ID"
echo ""

# 6. Get user finds
echo "6. Get User Finds"
test_endpoint "GET /api/users/{userId}/finds" "GET" "/api/users/$TEST_USER_ID/finds"
echo ""

# 7. Get stats
echo "7. Get Statistics"
test_endpoint "GET /api/stats" "GET" "/api/stats"
echo ""

# 8. Get player (should 404 if doesn't exist)
echo "8. Get Player (non-existent)"
test_endpoint "GET /api/players/{uuid} (404 expected)" "GET" "/api/players/$TEST_USER_ID" "" "404"
echo ""

# 9. Create/Update player
echo "9. Create/Update Player"
PLAYER_DATA="{\"player_name\":\"Test Player\"}"
test_endpoint "POST /api/players/{uuid}" "POST" "/api/players/$TEST_USER_ID" "$PLAYER_DATA"
echo ""

# 10. Get player (should work now)
echo "10. Get Player (existing)"
test_endpoint "GET /api/players/{uuid}" "GET" "/api/players/$TEST_USER_ID"
echo ""

# 11. Update object location
echo "11. Update Object Location"
LOCATION_DATA="{\"latitude\":40.0759,\"longitude\":-105.3009}"
test_endpoint "PUT /api/objects/{id} (location)" "PUT" "/api/objects/$TEST_OBJECT_ID" "$LOCATION_DATA"
echo ""

# 12. Update grounding height
echo "12. Update Grounding Height"
GROUNDING_DATA="{\"grounding_height\":1.5}"
test_endpoint "PUT /api/objects/{id}/grounding" "PUT" "/api/objects/$TEST_OBJECT_ID/grounding" "$GROUNDING_DATA"
echo ""

# 13. Update AR offset coordinates
echo "13. Update AR Offset Coordinates"
AR_OFFSET_DATA="{\"ar_origin_latitude\":40.0758,\"ar_origin_longitude\":-105.3008,\"ar_offset_x\":0.5,\"ar_offset_y\":0.0,\"ar_offset_z\":-0.3}"
test_endpoint "PUT /api/objects/{id}/ar-offset" "PUT" "/api/objects/$TEST_OBJECT_ID/ar-offset" "$AR_OFFSET_DATA"
echo ""

# 14. Mark object as found
echo "14. Mark Object as Found"
FOUND_DATA="{\"found_by\":\"$TEST_USER_ID\"}"
test_endpoint "POST /api/objects/{id}/found" "POST" "/api/objects/$TEST_OBJECT_ID/found" "$FOUND_DATA"
echo ""

# 15. Verify object is now found
echo "15. Verify Object is Found"
test_endpoint "GET /api/objects/{id} (should be found)" "GET" "/api/objects/$TEST_OBJECT_ID"
echo ""

# 16. Get user finds (should include the test object now)
echo "16. Get User Finds (after marking found)"
test_endpoint "GET /api/users/{userId}/finds" "GET" "/api/users/$TEST_USER_ID/finds"
echo ""

# 17. Unmark object as found
echo "17. Unmark Object as Found"
test_endpoint "DELETE /api/objects/{id}/found" "DELETE" "/api/objects/$TEST_OBJECT_ID/found"
echo ""

# 18. Verify object is unfound again
echo "18. Verify Object is Unfound"
test_endpoint "GET /api/objects/{id} (should be unfound)" "GET" "/api/objects/$TEST_OBJECT_ID"
echo ""

# 19. Get all players
echo "19. Get All Players"
test_endpoint "GET /api/players" "GET" "/api/players"
echo ""

# 20. Delete test object (cleanup)
echo "20. Delete Test Object (cleanup)"
test_endpoint "DELETE /api/objects/{id}" "DELETE" "/api/objects/$TEST_OBJECT_ID"
echo ""

# Summary
echo "=================================="
echo "Test Summary"
echo "=================================="
echo -e "${GREEN}Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
else
    echo -e "${GREEN}Failed: $FAILED${NC}"
fi
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    exit 1
fi



