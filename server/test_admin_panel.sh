#!/bin/bash
# Quick test script to check admin panel accessibility

echo "🔍 Admin Panel Connectivity Test"
echo "==============================="

# Test localhost (direct connection)
echo "1. Testing localhost:5001..."
if curl -s --max-time 3 http://localhost:5001/health > /dev/null 2>&1; then
    echo "✅ localhost:5001 - Working"
    echo "   Admin panel: http://localhost:5001/admin"
else
    echo "❌ localhost:5001 - Not accessible"
fi

# Test Colima IP (if known)
COLIMA_IP="${COLIMA_IP:-192.168.64.3}"
echo ""
echo "2. Testing Colima IP ($COLIMA_IP:5001)..."
if curl -s --max-time 3 http://$COLIMA_IP:5001/health > /dev/null 2>&1; then
    echo "✅ $COLIMA_IP:5001 - Working"
    echo "   Admin panel: http://$COLIMA_IP:5001/admin"
else
    echo "❌ $COLIMA_IP:5001 - Not accessible"
fi

# Test WiFi IP (if known)
WIFI_IP="${HOST_IP:-10.0.0.131}"
echo ""
echo "3. Testing WiFi IP ($WIFI_IP:5001)..."
if curl -s --max-time 3 http://$WIFI_IP:5001/health > /dev/null 2>&1; then
    echo "✅ $WIFI_IP:5001 - Working"
    echo "   Admin panel: http://$WIFI_IP:5001/admin"
else
    echo "❌ $WIFI_IP:5001 - Not accessible"
fi

# Check running processes
echo ""
echo "4. Running processes on port 5001:"
lsof -i :5001 2>/dev/null || echo "   No processes found"

# Check Docker containers
echo ""
echo "5. Docker containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep -E "(NAMES|cache-raiders)" || echo "   No Cache Raiders containers running"

echo ""
echo "💡 To fix admin panel access:"
echo "   1. Start Colima: colima start"
echo "   2. Detect your IP: ./detect_ip.sh"
echo "   3. Set IP and start server:"
echo "      export HOST_IP=10.0.0.131 && ./start-colima.sh"
echo "   4. Test again: ./test_admin_panel.sh"
