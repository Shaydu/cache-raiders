#!/bin/bash
# Fix iOS connection issues - comprehensive diagnostics and fixes

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "════════════════════════════════════════════════════════════════"
echo "🔧 iOS Connection Diagnostics & Fix"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Detect current WiFi IP
echo -e "${BLUE}1. Detecting WiFi IP Address${NC}"
WIFI_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "")
if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ipconfig getifaddr en1 2>/dev/null || echo "")
fi

if [ -z "$WIFI_IP" ]; then
    echo -e "${RED}✗ Could not detect WiFi IP${NC}"
    echo "Please ensure you're connected to WiFi"
    exit 1
else
    echo -e "${GREEN}✓ WiFi IP: $WIFI_IP${NC}"
fi

# 2. Check if socat is running
echo ""
echo -e "${BLUE}2. Checking Port Forwarding (socat)${NC}"
if lsof -i :5001 2>/dev/null | grep -q socat; then
    echo -e "${GREEN}✓ socat is running${NC}"
    SOCAT_PID=$(lsof -ti :5001 2>/dev/null | head -1)
    echo "  PID: $SOCAT_PID"
    
    # Check socat configuration
    SOCAT_CMD=$(ps -p $SOCAT_PID -o args= 2>/dev/null || echo "")
    echo "  Command: $SOCAT_CMD"
    
    # Verify it's forwarding to the right place
    if echo "$SOCAT_CMD" | grep -q "192.168.64.3:5001"; then
        echo -e "${GREEN}✓ Forwarding to Colima VM correctly${NC}"
    else
        echo -e "${RED}✗ socat not forwarding to correct destination${NC}"
        echo "  Expected: TCP:192.168.64.3:5001"
        echo "  Actual: $SOCAT_CMD"
    fi
else
    echo -e "${RED}✗ socat is NOT running${NC}"
    echo "  Port forwarding is required for iOS connections"
    echo "  Run: ./start-server.sh to set up port forwarding"
    exit 1
fi

# 3. Check Docker containers
echo ""
echo -e "${BLUE}3. Checking Docker Containers${NC}"
if docker ps 2>/dev/null | grep -q "cache-raiders-api"; then
    echo -e "${GREEN}✓ cache-raiders-api container is running${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep cache-raiders || true
else
    echo -e "${RED}✗ cache-raiders-api container is NOT running${NC}"
    echo "  Run: cd server && docker compose up -d"
    exit 1
fi

# 4. Test Colima VM connection (should work)
echo ""
echo -e "${BLUE}4. Testing Colima VM Connection${NC}"
if curl -s --connect-timeout 3 http://192.168.64.3:5001/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Colima VM (192.168.64.3:5001) is accessible${NC}"
else
    echo -e "${RED}✗ Colima VM is NOT accessible${NC}"
    echo "  Docker container may not be running properly"
    exit 1
fi

# 5. Test localhost through socat (should work)
echo ""
echo -e "${BLUE}5. Testing localhost through socat${NC}"
if curl -s --connect-timeout 3 http://127.0.0.1:5001/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ localhost:5001 is accessible (socat working)${NC}"
else
    echo -e "${RED}✗ localhost:5001 is NOT accessible${NC}"
    echo "  socat may not be forwarding correctly"
    exit 1
fi

# 6. Check macOS Firewall
echo ""
echo -e "${BLUE}6. Checking macOS Firewall${NC}"
FIREWALL_STATUS=$(sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")
echo "  Firewall status: $FIREWALL_STATUS"

if echo "$FIREWALL_STATUS" | grep -q "enabled"; then
    echo -e "${YELLOW}⚠ Firewall is ENABLED${NC}"
    echo ""
    echo "  The firewall may be blocking incoming connections on port 5001."
    echo "  To fix this, you have two options:"
    echo ""
    echo "  ${GREEN}Option 1: Allow Python through firewall (Recommended)${NC}"
    echo "    1. Open System Settings → Network → Firewall"
    echo "    2. Click 'Options'"
    echo "    3. Find 'Python' in the list"
    echo "    4. Change to 'Allow incoming connections'"
    echo ""
    echo "  ${GREEN}Option 2: Temporarily disable firewall (Testing only)${NC}"
    echo "    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off"
    echo ""
    read -p "  Would you like to check firewall rules for Python? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "  Checking if Python is allowed:"
        sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null | grep -i python || echo "  No Python entries found"
    fi
else
    echo -e "${GREEN}✓ Firewall is disabled or allowing connections${NC}"
fi

# 7. Check network interfaces
echo ""
echo -e "${BLUE}7. Network Interface Information${NC}"
echo "  Available interfaces with IP addresses:"
ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | grep -B1 "inet " | grep -v "127.0.0.1" | grep -v "::1" | head -20

# 8. Test from another terminal if possible
echo ""
echo -e "${BLUE}8. Connection Test Summary${NC}"
echo "  ✓ Colima VM: http://192.168.64.3:5001 - ${GREEN}Working${NC}"
echo "  ✓ Localhost: http://127.0.0.1:5001 - ${GREEN}Working${NC}"
echo "  ? WiFi IP: http://$WIFI_IP:5001 - ${YELLOW}Cannot test from same machine${NC}"
echo ""
echo -e "${YELLOW}Note: macOS routing prevents testing your own WiFi IP from the same machine.${NC}"
echo -e "${YELLOW}This does NOT mean iOS devices can't connect!${NC}"

# 9. Provide iOS testing instructions
echo ""
echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}📱 iOS Device Testing Instructions${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Ensure your iOS device is on the SAME WiFi network as this Mac"
echo ""
echo "2. In the Cache Raiders iOS app:"
echo "   • Open Settings"
echo "   • Enter Server URL: ${GREEN}http://$WIFI_IP:5001${NC}"
echo "   • Tap 'Save URL'"
echo "   • Tap 'Test Connection'"
echo ""
echo "3. If connection still fails, check:"
echo "   • Both devices are on the same WiFi network (not guest network)"
echo "   • WiFi router allows device-to-device communication"
echo "   • macOS Firewall allows Python (see Option 1 above)"
echo ""
echo "4. Alternative: Use QR Code"
echo "   • Open: ${GREEN}http://192.168.64.3:5001/admin${NC} in your browser"
echo "   • Scan the QR code with the iOS app"
echo ""

# 10. Suggest fixes
echo "════════════════════════════════════════════════════════════════"
echo -e "${YELLOW}🔧 Potential Fixes${NC}"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo "If iOS connection still fails after checking firewall:"
echo ""
echo "1. ${BLUE}Restart port forwarding:${NC}"
echo "   pkill -f 'socat.*5001'"
echo "   socat TCP-LISTEN:5001,bind=0.0.0.0,fork,reuseaddr TCP:192.168.64.3:5001 &"
echo ""
echo "2. ${BLUE}Check WiFi router settings:${NC}"
echo "   • Disable 'AP Isolation' or 'Client Isolation'"
echo "   • Ensure devices can communicate with each other"
echo ""
echo "3. ${BLUE}Try using the Mac's IP from another device first:${NC}"
echo "   • From another computer/phone on same WiFi"
echo "   • Open: http://$WIFI_IP:5001/health"
echo "   • This verifies the network allows device-to-device communication"
echo ""
echo "4. ${BLUE}Update HOST_IP if your WiFi IP changed:${NC}"
echo "   export HOST_IP=$WIFI_IP"
echo "   docker compose down && docker compose up -d"
echo ""

echo "════════════════════════════════════════════════════════════════"
echo -e "${GREEN}✅ Diagnostics Complete${NC}"
echo "════════════════════════════════════════════════════════════════"

