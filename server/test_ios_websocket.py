#!/usr/bin/env python3
"""
Test script that connects EXACTLY like the iOS app does:
- Uses raw WebSocket (not Socket.IO client library)
- Manual Socket.IO protocol implementation
- Same URL construction as iOS WebSocketService.swift
- Same timeout values

This helps diagnose why iOS WebSocket times out while admin panel works.
"""

import asyncio
import websockets
import json
import time
import argparse
import sys
from datetime import datetime

# ANSI colors for output
class Colors:
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    RESET = '\033[0m'
    BOLD = '\033[1m'

def log(emoji: str, message: str, color: str = Colors.RESET):
    timestamp = datetime.now().strftime('%H:%M:%S.%f')[:-3]
    print(f"{color}[{timestamp}] {emoji} {message}{Colors.RESET}")

def log_success(message: str):
    log("✅", message, Colors.GREEN)

def log_error(message: str):
    log("❌", message, Colors.RED)

def log_warning(message: str):
    log("⚠️", message, Colors.YELLOW)

def log_info(message: str):
    log("ℹ️", message, Colors.BLUE)

def log_send(message: str):
    log("📤", f"SEND: {message}", Colors.CYAN)

def log_recv(message: str):
    log("📨", f"RECV: {message}", Colors.CYAN)


async def test_ios_websocket_connection(base_url: str, timeout: float = 30.0):
    """
    Test WebSocket connection exactly like iOS app does.
    
    iOS WebSocketService.swift does this:
    1. Converts http:// to ws:// (or https:// to wss://)
    2. Constructs URL: {ws_url}/socket.io/?EIO=4&transport=websocket
    3. Opens WebSocket connection
    4. Waits for "0{...}" session info packet
    5. Sends "40" to connect to default namespace
    6. Waits for "40" or "40{...}" namespace confirmation
    7. Connection is now established
    """
    
    print(f"\n{Colors.BOLD}{'='*60}")
    print(f"iOS WebSocket Connection Test")
    print(f"{'='*60}{Colors.RESET}\n")
    
    # Step 1: Construct WebSocket URL exactly like iOS does
    log_info(f"Base URL: {base_url}")
    
    # iOS: baseURL.replacingOccurrences(of: "http://", with: "ws://")
    #              .replacingOccurrences(of: "https://", with: "wss://")
    ws_url = base_url.replace("http://", "ws://").replace("https://", "wss://")
    
    # iOS: "\(httpURL)/socket.io/?EIO=4&transport=websocket"
    full_ws_url = f"{ws_url}/socket.io/?EIO=4&transport=websocket"
    
    log_info(f"WebSocket URL (iOS-style): {full_ws_url}")
    log_info(f"Timeout: {timeout} seconds (iOS default: 30s)")
    
    print()
    
    # Track handshake state (matches iOS enum)
    class HandshakeState:
        NOT_STARTED = "notStarted"
        WAITING_FOR_SESSION_INFO = "waitingForSessionInfo"
        WAITING_FOR_NAMESPACE_CONFIRMATION = "waitingForNamespaceConfirmation"
        COMPLETED = "completed"
    
    handshake_state = HandshakeState.WAITING_FOR_SESSION_INFO
    session_id = None
    start_time = time.time()
    
    results = {
        "connected": False,
        "handshake_completed": False,
        "session_id": None,
        "ping_pong_works": False,
        "connection_time": None,
        "error": None,
        "messages_received": [],
    }
    
    try:
        log_info("Opening WebSocket connection...")
        
        # Connect with timeout (iOS uses URLSession with timeout)
        async with asyncio.timeout(timeout):
            async with websockets.connect(
                full_ws_url,
                # No additional headers - iOS doesn't add any special headers
                # Just like URLSessionWebSocketTask default behavior
            ) as websocket:
                results["connected"] = True
                connection_time = time.time() - start_time
                log_success(f"WebSocket TCP connection established ({connection_time:.3f}s)")
                
                # Step 2: Wait for Socket.IO session info packet
                # iOS: Waits for message starting with "0{"
                log_info("Waiting for Socket.IO session info (packet starting with '0{')...")
                
                while handshake_state != HandshakeState.COMPLETED:
                    try:
                        message = await asyncio.wait_for(websocket.recv(), timeout=10.0)
                        log_recv(message[:100] + "..." if len(message) > 100 else message)
                        results["messages_received"].append(message)
                        
                        # Handle Socket.IO handshake (matches iOS handleMessage)
                        if message.startswith("0{"):
                            # Received session info packet
                            try:
                                session_data = json.loads(message[1:])  # Remove "0" prefix
                                session_id = session_data.get("sid")
                                ping_interval = session_data.get("pingInterval", 25000)
                                ping_timeout = session_data.get("pingTimeout", 5000)
                                results["session_id"] = session_id
                                
                                log_success(f"Received Socket.IO session info!")
                                log_info(f"  Session ID: {session_id}")
                                log_info(f"  Ping interval: {ping_interval}ms")
                                log_info(f"  Ping timeout: {ping_timeout}ms")
                            except json.JSONDecodeError:
                                log_warning("Could not parse session info JSON")
                            
                            # iOS: sendSocketIOPacket("40")
                            handshake_state = HandshakeState.WAITING_FOR_NAMESPACE_CONFIRMATION
                            log_send("40 (namespace connection request)")
                            await websocket.send("40")
                            
                        elif message == "40" or message.startswith("40{"):
                            # Namespace confirmation received
                            handshake_state = HandshakeState.COMPLETED
                            results["handshake_completed"] = True
                            results["connection_time"] = time.time() - start_time
                            
                            if message.startswith("40{"):
                                try:
                                    ns_data = json.loads(message[2:])
                                    ns_sid = ns_data.get("sid")
                                    log_success(f"Socket.IO handshake complete! Namespace SID: {ns_sid}")
                                except:
                                    log_success("Socket.IO handshake complete! (with session data)")
                            else:
                                log_success("Socket.IO handshake complete!")
                            
                            log_info(f"Total handshake time: {results['connection_time']:.3f}s")
                            
                        elif message == "2":
                            # Server ping - respond with pong
                            log_recv("Server ping (packet '2')")
                            log_send("3 (pong response)")
                            await websocket.send("3")
                            results["ping_pong_works"] = True
                            
                        elif message == "3":
                            # Pong response to our ping
                            log_recv("Pong response (packet '3')")
                            results["ping_pong_works"] = True
                            
                        elif message.startswith("42["):
                            # Socket.IO event message
                            log_info(f"Received Socket.IO event: {message[:80]}...")
                            
                    except asyncio.TimeoutError:
                        log_error(f"Timeout waiting for message (state: {handshake_state})")
                        results["error"] = f"Timeout in state: {handshake_state}"
                        break
                
                if handshake_state == HandshakeState.COMPLETED:
                    # Test ping/pong like iOS does
                    log_info("\nTesting ping/pong...")
                    log_send("2 (ping)")
                    await websocket.send("2")
                    
                    try:
                        pong = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                        log_recv(pong)
                        if pong == "3":
                            log_success("Ping/pong working!")
                            results["ping_pong_works"] = True
                        else:
                            log_warning(f"Unexpected pong response: {pong}")
                    except asyncio.TimeoutError:
                        log_warning("Ping/pong timeout (server may not respond to client pings)")
                    
                    # Keep connection open briefly to receive any events
                    log_info("\nListening for events (5 seconds)...")
                    try:
                        while True:
                            message = await asyncio.wait_for(websocket.recv(), timeout=5.0)
                            log_recv(message[:100] + "..." if len(message) > 100 else message)
                            results["messages_received"].append(message)
                            
                            if message == "2":
                                log_send("3 (pong)")
                                await websocket.send("3")
                    except asyncio.TimeoutError:
                        log_info("No more events received")
                    
    except asyncio.TimeoutError:
        elapsed = time.time() - start_time
        log_error(f"Connection timeout after {elapsed:.1f}s (iOS timeout: {timeout}s)")
        results["error"] = f"Connection timeout after {elapsed:.1f}s"
        
    except websockets.exceptions.InvalidStatusCode as e:
        log_error(f"WebSocket handshake failed: HTTP {e.status_code}")
        results["error"] = f"HTTP {e.status_code} during WebSocket upgrade"
        
    except ConnectionRefusedError:
        log_error("Connection refused - server not running or wrong port")
        results["error"] = "Connection refused"
        
    except OSError as e:
        log_error(f"Network error: {e}")
        results["error"] = str(e)
        
    except Exception as e:
        log_error(f"Unexpected error: {type(e).__name__}: {e}")
        results["error"] = str(e)
    
    # Print summary
    print(f"\n{Colors.BOLD}{'='*60}")
    print(f"Test Results Summary")
    print(f"{'='*60}{Colors.RESET}\n")
    
    print(f"  WebSocket Connected:    {'✅ Yes' if results['connected'] else '❌ No'}")
    print(f"  Handshake Completed:    {'✅ Yes' if results['handshake_completed'] else '❌ No'}")
    print(f"  Session ID:             {results['session_id'] or 'N/A'}")
    print(f"  Ping/Pong Works:        {'✅ Yes' if results['ping_pong_works'] else '❌ No'}")
    print(f"  Connection Time:        {results['connection_time']:.3f}s" if results['connection_time'] else "  Connection Time:        N/A")
    print(f"  Messages Received:      {len(results['messages_received'])}")
    
    if results["error"]:
        print(f"\n  {Colors.RED}Error: {results['error']}{Colors.RESET}")
    
    # Diagnosis
    print(f"\n{Colors.BOLD}Diagnosis:{Colors.RESET}")
    
    if results["handshake_completed"]:
        print(f"  {Colors.GREEN}✅ Connection works exactly like iOS app would connect!{Colors.RESET}")
        print(f"  If iOS is still timing out, the issue is likely:")
        print(f"    - iOS App Transport Security blocking HTTP")
        print(f"    - Network path difference (iOS on different subnet)")
        print(f"    - iOS firewall/network restrictions")
    elif results["connected"] and not results["handshake_completed"]:
        print(f"  {Colors.YELLOW}⚠️ TCP connected but Socket.IO handshake failed{Colors.RESET}")
        print(f"  This suggests the server's Socket.IO isn't responding properly")
        print(f"  Check if Flask-SocketIO is running correctly")
    else:
        print(f"  {Colors.RED}❌ Could not establish WebSocket connection{Colors.RESET}")
        print(f"  Possible causes:")
        print(f"    - Server not running")
        print(f"    - Wrong IP/port")
        print(f"    - Firewall blocking connection")
        print(f"    - Docker port not exposed properly")
    
    print()
    return results


async def test_http_first(base_url: str):
    """Test HTTP connectivity first (like iOS APIService health check)."""
    import aiohttp
    
    print(f"\n{Colors.BOLD}Testing HTTP connectivity first...{Colors.RESET}")
    
    health_url = f"{base_url}/health"
    log_info(f"Testing: {health_url}")
    
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(health_url, timeout=aiohttp.ClientTimeout(total=5)) as response:
                if response.status == 200:
                    data = await response.json()
                    log_success(f"HTTP health check passed: {data}")
                    return True
                else:
                    log_error(f"HTTP health check failed: {response.status}")
                    return False
    except Exception as e:
        log_error(f"HTTP health check error: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Test WebSocket connection exactly like iOS app does",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Test local server
  python test_ios_websocket.py http://localhost:5001
  
  # Test with specific IP (like iOS would use)
  python test_ios_websocket.py http://192.168.68.53:5001
  
  # Test with custom timeout
  python test_ios_websocket.py http://192.168.68.53:5001 --timeout 10
  
  # Skip HTTP check
  python test_ios_websocket.py http://192.168.68.53:5001 --skip-http
        """
    )
    
    parser.add_argument("url", help="Base URL (e.g., http://192.168.68.53:5001)")
    parser.add_argument("--timeout", "-t", type=float, default=30.0, 
                        help="Connection timeout in seconds (default: 30, same as iOS)")
    parser.add_argument("--skip-http", action="store_true",
                        help="Skip HTTP health check before WebSocket test")
    
    args = parser.parse_args()
    
    # Normalize URL
    base_url = args.url.rstrip("/")
    if not base_url.startswith("http"):
        base_url = f"http://{base_url}"
    
    print(f"\n{Colors.BOLD}iOS WebSocket Connection Simulator{Colors.RESET}")
    print(f"This script connects EXACTLY like the iOS app does.\n")
    
    async def run_tests():
        # Test HTTP first (like iOS does health checks)
        if not args.skip_http:
            http_ok = await test_http_first(base_url)
            if not http_ok:
                log_warning("HTTP failed - WebSocket will likely fail too")
                log_info("Continuing with WebSocket test anyway...")
        
        # Test WebSocket exactly like iOS
        await test_ios_websocket_connection(base_url, args.timeout)
    
    asyncio.run(run_tests())


if __name__ == "__main__":
    main()


















