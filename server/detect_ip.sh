#!/bin/bash
# IP Detection Helper Script for Cache Raiders

echo "🔍 Cache Raiders - Network Interface Detection"
echo "=============================================="

echo "1. System Network Information:"
echo "   Hostname: $(hostname)"
echo "   OS: $(uname -s) $(uname -r)"

echo ""
echo "2. Available network interfaces:"
if command -v networksetup >/dev/null 2>&1; then
    echo "   Hardware ports:"
    networksetup -listallhardwareports 2>/dev/null | grep -A1 "Hardware Port:" | head -10
else
    echo "   Interfaces (ifconfig):"
    ifconfig 2>/dev/null | grep -E "^[a-z]" | awk '{print "     " $1}' | tr -d ':' || echo "     (ifconfig not available)"
fi

echo ""
echo "3. Current IP addresses:"
echo "   All IPs found:"
ifconfig 2>/dev/null | grep -E "inet [0-9]" | grep -v 127.0.0.1 | awk '{print "     " $1 " " $2}' || echo "     (no IPs detected via ifconfig)"

echo ""
echo "   Default route interface:"
default_iface=$(netstat -rn 2>/dev/null | grep -E '^default|^0\.0\.0\.0' | head -1 | awk '{print $NF}' || echo "")
if [ -n "$default_iface" ]; then
    default_ip=$(ipconfig getifaddr $default_iface 2>/dev/null || echo "")
    echo "     Interface: $default_iface, IP: ${default_ip:-not found}"
else
    echo "     (no default route found)"
fi

echo ""
echo "4. Testing common interfaces:"
for iface in en0 en1 en2 en3 en4 en5 en6 en7 en8 en9 eth0 wlan0; do
    if ipconfig getifaddr $iface >/dev/null 2>&1; then
        ip=$(ipconfig getifaddr $iface 2>/dev/null)
        status="✅ ACTIVE"
        if [[ $ip =~ ^169\.254\. ]]; then
            status="⚠️  LINK-LOCAL"
        elif [[ $ip =~ ^192\.168\.64\. ]]; then
            status="🚫 COLIMA-VM"
        fi
        echo "     $iface: $ip ($status)"
    fi
done

echo ""
echo "5. Recommended IP for iOS connections:"
recommended_ip=$(ifconfig 2>/dev/null | grep -E "inet [0-9]" | grep -v 127.0.0.1 | grep -v 169.254 | grep -v 192.168.64 | awk '{print $2}' | head -1 || echo "")
if [ -n "$recommended_ip" ]; then
    echo "   🎯 Use this IP: $recommended_ip"
    echo "   export HOST_IP=$recommended_ip"
else
    echo "   ❌ No suitable IP found automatically"
fi

echo ""
echo "6. Usage Instructions:"
echo "   💡 To start server with detected IP:"
echo "      export HOST_IP=$recommended_ip && ./start-colima.sh"
echo ""
echo "   💡 To manually set IP:"
echo "      export HOST_IP=192.168.1.100  # replace with your IP"
echo "      ./start-colima.sh"
echo ""
echo "   💡 To save IP for future use:"
echo "      echo '$recommended_ip' > .last_host_ip"
