"""
CacheRaiders API Server
Simple REST API for tracking loot box objects, their locations, and who found them.
"""
from flask import Flask, request, jsonify, send_from_directory, Response
from flask_cors import CORS
from flask_socketio import SocketIO, emit
import sqlite3
import os
import math
import socket
import io
import qrcode
import logging
import threading
import time
import requests
import traceback
from datetime import datetime
from typing import Optional, List, Dict
from dotenv import load_dotenv

# Set up file logging for map requests debugging
log_dir = os.path.join(os.path.dirname(__file__), 'logs')
os.makedirs(log_dir, exist_ok=True)
map_log_file = os.path.join(log_dir, 'map_requests.log')

# Configure map request logger
map_logger = logging.getLogger('map_requests')
map_logger.setLevel(logging.DEBUG)
map_handler = logging.FileHandler(map_log_file, mode='a')
map_handler.setLevel(logging.DEBUG)
formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
map_handler.setFormatter(formatter)
map_logger.addHandler(map_handler)
map_logger.propagate = False  # Don't propagate to root logger

# Load environment variables from .env file (never commit this file!)
# But only if not running in a Docker container (container env vars take precedence)
if not os.getenv("DOCKER_CONTAINER"):
    load_dotenv()

# Import LLM service
try:
    from llm_service import llm_service
    LLM_AVAILABLE = True
except ImportError as e:
    print(f"⚠️ LLM service not available: {e}")
    LLM_AVAILABLE = False
    llm_service = None

# Import Treasure Map service
try:
    from treasure_map_service import treasure_map_service
    TREASURE_MAP_AVAILABLE = True
except ImportError as e:
    print(f"⚠️ Treasure Map service not available: {e}")
    TREASURE_MAP_AVAILABLE = False
    treasure_map_service = None

# Import Treasure Hunt Stages (Stage 2: IOU/Corgi storyline)
try:
    from treasure_hunt_stages import register_stages_blueprint
    STAGES_AVAILABLE = True
except ImportError as e:
    print(f"⚠️ Treasure Hunt Stages not available: {e}")
    STAGES_AVAILABLE = False
    register_stages_blueprint = None

app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)  # Enable CORS for iOS app
# Use 'threading' instead of 'eventlet' for Python 3.12 compatibility
# Configure Socket.IO with explicit ping/pong settings for better compatibility
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode='threading',
    ping_interval=25,  # Server sends ping every 25 seconds
    ping_timeout=30    # Increased to 30 seconds for slow networks
)  # Enable WebSocket support

# Register Treasure Hunt Stages blueprint (Stage 2: IOU/Corgi storyline)
if STAGES_AVAILABLE and register_stages_blueprint:
    register_stages_blueprint(app)

# Database file path
DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

# In-memory store for user locations (device_uuid -> latest location)
# This allows the web map to show where users are currently located
user_locations: Dict[str, Dict] = {}

# Location update interval setting (in milliseconds, default 1000ms = 1 second)
location_update_interval_ms: int = 1000

# Game mode setting (default: "open", will be loaded from database on startup)
game_mode: str = "open"

# Track connected WebSocket clients (session_id -> device_uuid)
# Also track reverse mapping (device_uuid -> set of session_ids) for multiple connections
connected_clients: Dict[str, str] = {}  # session_id -> device_uuid
client_sessions: Dict[str, set] = {}  # device_uuid -> set of session_ids

def get_local_ip_dynamic(request_context=None):
    """Get the local network IP address dynamically (always detects current IP).
    Works across network changes (WiFi hotspots, network switching, etc.)
    Filters out Docker internal IPs and localhost.
    
    Args:
        request_context: Optional Flask request object to use request host as hint in Docker
    """
    import socket
    
    # Helper to check if IP is a Docker/internal network IP
    def is_docker_or_internal_ip(ip):
        """Check if IP is Docker internal or not a real network interface."""
        if not ip or ip.startswith('127.'):
            return True
        # Docker bridge networks: 172.16-31.x.x
        # Filter out common Docker/internal ranges
        parts = ip.split('.')
        if len(parts) == 4:
            try:
                first_octet = int(parts[0])
                second_octet = int(parts[1])
                # Docker bridge: 172.16.0.0 - 172.31.255.255
                if first_octet == 172 and 16 <= second_octet <= 31:
                    return True
                # Docker Desktop on Mac: 192.168.65.x
                if first_octet == 192 and second_octet == 168 and parts[2] == '65':
                    return True
            except ValueError:
                pass
        return False
    
    # Helper to check if IP is routable (not localhost, not Docker internal)
    def is_routable_ip(ip):
        """Check if IP is routable from other devices on the network."""
        if not ip:
            return False
        # Must not be localhost
        if ip.startswith('127.'):
            return False
        # Must not be Docker internal
        if is_docker_or_internal_ip(ip):
            return False
        # Must be a valid IPv4 format
        try:
            socket.inet_aton(ip)
            return True
        except socket.error:
            return False
    
    # Method 0: If we have a request context and we're in Docker, use the request host as hint
    # This is especially useful when running in Docker - the request host tells us what IP was used to reach us
    if request_context:
        try:
            host = request_context.host.split(':')[0] if ':' in request_context.host else request_context.host
            # If host is a valid routable IP (not localhost, not Docker internal), use it
            if is_routable_ip(host):
                print(f"🌐 [Dynamic] Using request host as IP (Docker hint): {host}")
                return host
            # Also check remote_addr - if it's from the same network, we can infer our IP
            remote_addr = request_context.remote_addr
            if remote_addr and is_routable_ip(remote_addr):
                # Remote addr is the client's IP, but if it's on same network, we might be able to infer
                # For now, we'll use it as a last resort hint
                pass
        except Exception as e:
            print(f"⚠️ Error using request context: {e}")
    
    # Method 1: Connect to external address to determine route (works in Docker and regular)
    # This method finds the IP that would be used for external connections
    detected_docker_ip = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # Connect to a public DNS server (doesn't actually connect, just determines route)
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            if ip and is_routable_ip(ip):
                print(f"🌐 [Dynamic] Detected IP via socket connection: {ip}")
                return ip
            # If we got a Docker IP, save it and try alternative methods
            elif ip and is_docker_or_internal_ip(ip):
                detected_docker_ip = ip
                print(f"⚠️ [Dynamic] Socket method returned Docker/internal IP {ip}, trying alternatives...")
        except Exception as e:
            print(f"⚠️ Socket connection method error: {e}")
        finally:
            s.close()
    except Exception as e:
        print(f"⚠️ Error with socket connection method: {e}")
    
    # Method 2: Try netifaces if available (more reliable interface detection)
    # This can work in Docker if host network interfaces are accessible
    try:
        import netifaces
        interfaces = netifaces.interfaces()
        # Prioritize common WiFi/Ethernet interfaces
        priority_interfaces = ['en0', 'en1', 'wlan0', 'eth0', 'wlp']
        all_interfaces = sorted(interfaces, key=lambda x: (
            0 if any(x.startswith(prefix) for prefix in priority_interfaces) else 1,
            x
        ))
        
        for interface in all_interfaces:
            # Skip loopback and Docker interfaces
            if interface.startswith('lo') or interface.startswith('docker') or interface.startswith('veth'):
                continue
            try:
                addrs = netifaces.ifaddresses(interface)
                if netifaces.AF_INET in addrs:
                    for addr_info in addrs[netifaces.AF_INET]:
                        ip = addr_info.get('addr')
                        if ip and is_routable_ip(ip):
                            print(f"🌐 [Dynamic] Detected IP from interface {interface}: {ip}")
                            return ip
            except (ValueError, KeyError):
                continue
    except ImportError:
        # netifaces not available, that's okay
        pass
    except Exception as e:
        print(f"⚠️ Error checking network interfaces: {e}")
    
    # Method 3: Try hostname resolution (fallback)
    try:
        hostname = socket.gethostname()
        ip = socket.gethostbyname(hostname)
        if ip and is_routable_ip(ip):
            print(f"🌐 [Dynamic] Detected IP from hostname {hostname}: {ip}")
            return ip
    except (socket.gaierror, Exception) as e:
        pass
    
    # If we detected a Docker IP but couldn't find a routable one, warn but don't fail
    if detected_docker_ip:
        print(f"⚠️ Running in Docker (detected {detected_docker_ip}) but couldn't detect host network IP")
        print(f"   Try accessing the admin panel via the host machine's IP address")
        print(f"   Or set HOST_IP environment variable in docker-compose.yml")
    
    # Last resort: return localhost (but this won't work from other devices)
    print("⚠️ Could not detect network IP dynamically, using 127.0.0.1 (not routable from other devices)")
    return '127.0.0.1'

def get_local_ip():
    """Get the local network IP address.

    Requires HOST_IP environment variable to be set explicitly.
    No fallback detection - if HOST_IP is not set, raises an error.
    """
    # Check if HOST_IP environment variable is set (required)
    host_ip = os.environ.get('HOST_IP')
    if host_ip:
        print(f"🌐 Using HOST_IP from environment: {host_ip}")
        return host_ip

    # No fallback - raise error if HOST_IP is not set
    error_msg = (
        "❌ HOST_IP environment variable is not set!\n"
        "The server cannot determine the network IP address for iOS devices to connect.\n\n"
        "To fix this:\n"
        "1. If using Docker, set HOST_IP in docker-compose.yml or environment\n"
        "2. If running directly, set HOST_IP environment variable\n"
        "3. Use start-server.sh which automatically detects and sets HOST_IP\n\n"
        "Example: export HOST_IP=192.168.1.100\n"
        "Find your IP with: ipconfig getifaddr en0 (on Mac)"
    )
    print(error_msg)
    raise RuntimeError("HOST_IP environment variable must be set")

def get_db_connection():
    """Get a database connection with timeout for handling concurrent access."""
    conn = sqlite3.connect(DB_PATH, timeout=10.0)  # 10 second timeout for locked database
    conn.row_factory = sqlite3.Row
    # Enable WAL mode for better concurrency (allows reads while writes are happening)
    conn.execute('PRAGMA journal_mode=WAL')
    return conn

def init_db():
    """Initialize the database with required tables."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Objects table - tracks all loot box objects
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS objects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            radius REAL NOT NULL,
            created_at TEXT NOT NULL,
            created_by TEXT,
            grounding_height REAL
        )
    ''')
    
    # Add optional columns if they don't exist (for existing databases)
    optional_columns = [
        ('grounding_height', 'REAL'),
        ('ar_origin_latitude', 'REAL'),
        ('ar_origin_longitude', 'REAL'),
        ('ar_offset_x', 'REAL'),
        ('ar_offset_y', 'REAL'),
        ('ar_offset_z', 'REAL'),
        ('ar_placement_timestamp', 'TEXT'),
        ('ar_anchor_transform', 'TEXT')  # For millimeter-precise AR positioning
    ]
    
    for column_name, column_type in optional_columns:
        try:
            # Sanitize column_name and column_type to prevent SQL injection
            if not all(c.isalnum() or c == '_' for c in column_name):
                print(f"⚠️ Skipping invalid column name: {column_name}")
                continue
            if column_type.upper() not in ['TEXT', 'REAL', 'INTEGER', 'NUMERIC', 'BLOB']:
                print(f"⚠️ Skipping invalid column type: {column_type}")
                continue
            # Use parameterized query to safely add columns
            # Note: SQLite doesn't support parameterized DDL, so we have to use string formatting
            # but with proper validation above to prevent SQL injection
            safe_column_name = ''.join(c for c in column_name if c.isalnum() or c == '_')
            safe_column_type = column_type.upper() if column_type.upper() in ['TEXT', 'REAL', 'INTEGER', 'NUMERIC', 'BLOB'] else 'TEXT'
            # Quote column name to handle special characters properly
            cursor.execute(f'ALTER TABLE objects ADD COLUMN "{safe_column_name}" {safe_column_type}')
        except sqlite3.OperationalError:
            pass  # Column already exists
    
    # Finds table - tracks who found which objects
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS finds (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            object_id TEXT NOT NULL,
            found_by TEXT NOT NULL,
            found_at TEXT NOT NULL,
            FOREIGN KEY (object_id) REFERENCES objects (id)
        )
    ''')
    
    # Create index for faster lookups
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_object_id ON finds(object_id)
    ''')
    
    # Players table - maps device UUID to player name
    # Device UUID is the unique identifier, player names can be duplicated
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS players (
            device_uuid TEXT PRIMARY KEY,
            player_name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    ''')
    
    # Remove any UNIQUE constraint on player_name if it exists
    # SQLite doesn't support DROP CONSTRAINT, so we need to check and recreate if needed
    try:
        # Check if there's a UNIQUE constraint on player_name
        cursor.execute("""
            SELECT sql FROM sqlite_master 
            WHERE type='table' AND name='players'
        """)
        table_sql = cursor.fetchone()
        if table_sql and table_sql[0] and 'UNIQUE' in table_sql[0] and 'player_name' in table_sql[0]:
            print("⚠️ Found UNIQUE constraint on player_name - removing it to allow duplicate names")
            # Recreate table without UNIQUE constraint
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS players_new (
                    device_uuid TEXT PRIMARY KEY,
                    player_name TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            ''')
            # Copy data
            cursor.execute('''
                INSERT INTO players_new (device_uuid, player_name, created_at, updated_at)
                SELECT device_uuid, player_name, created_at, updated_at FROM players
            ''')
            # Drop old table
            cursor.execute('DROP TABLE players')
            # Rename new table
            cursor.execute('ALTER TABLE players_new RENAME TO players')
            print("✅ Removed UNIQUE constraint on player_name")
    except (sqlite3.OperationalError, TypeError, IndexError) as e:
        # Table might not exist yet, constraint doesn't exist, or sql is None - that's fine
        pass
    
    # Create index for faster lookups by player name (non-unique, allows duplicates)
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_player_name ON players(player_name)
    ''')

    # User last locations table - stores the most recent location per device
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS user_last_locations (
            device_uuid TEXT PRIMARY KEY,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            updated_at TEXT NOT NULL
        )
    ''')
    
    # NPCs table - tracks all NPCs (Captain Bones, Corgi, etc.)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS npcs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            npc_type TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            created_at TEXT NOT NULL,
            created_by TEXT,
            ar_origin_latitude REAL,
            ar_origin_longitude REAL,
            ar_offset_x REAL,
            ar_offset_y REAL,
            ar_offset_z REAL,
            ar_placement_timestamp TEXT
        )
    ''')
    
    # Settings table - stores application settings (game mode, etc.)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    ''')
    
    # Treasure hunts table - stores generated treasure locations per user
    # This ensures the X location and clues are generated ONCE and persist across requests
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS treasure_hunts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_uuid TEXT NOT NULL,
            treasure_latitude REAL NOT NULL,
            treasure_longitude REAL NOT NULL,
            origin_latitude REAL NOT NULL,
            origin_longitude REAL NOT NULL,
            map_piece_1_json TEXT,
            map_piece_2_json TEXT,
            status TEXT DEFAULT 'active',
            created_at TEXT NOT NULL,
            completed_at TEXT
        )
    ''')
    
    # Create index for faster lookups by device_uuid and status
    cursor.execute('''
        CREATE INDEX IF NOT EXISTS idx_treasure_hunts_device_status 
        ON treasure_hunts (device_uuid, status)
    ''')
    
    # Initialize default game mode if not exists
    cursor.execute('SELECT value FROM settings WHERE key = ?', ('game_mode',))
    if not cursor.fetchone():
        cursor.execute('''
            INSERT INTO settings (key, value, updated_at)
            VALUES (?, ?, ?)
        ''', ('game_mode', 'open', datetime.utcnow().isoformat()))
        print("✅ Initialized default game mode: open")
    
    conn.commit()
    conn.close()
    print("✅ Database initialized")

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint."""
    # Log connection attempts for debugging
    print(f"🏥 Health check from {request.remote_addr} (Host: {request.host})")
    try:
        server_ip = get_local_ip()
    except:
        server_ip = 'unknown'
    return jsonify({
        'status': 'healthy', 
        'timestamp': datetime.utcnow().isoformat(),
        'server_ip': server_ip,
        'llm_available': LLM_AVAILABLE
    })

@app.route('/api/objects', methods=['GET'])
def get_objects():
    """Get all objects, optionally filtered by location."""
    try:
        latitude = request.args.get('latitude', type=float)
        longitude = request.args.get('longitude', type=float)
        radius = request.args.get('radius', type=float, default=10000.0)  # Default 10km
        include_found = request.args.get('include_found', 'false').lower() == 'true'
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Check which AR columns exist in the database
        cursor.execute("PRAGMA table_info(objects)")
        columns_info = cursor.fetchall()
        column_names = [col[1] for col in columns_info]
        
        # Build SELECT clause dynamically based on available columns
        base_columns = [
            'o.id', 'o.name', 'o.type', 'o.latitude', 'o.longitude', 
            'o.radius', 'o.created_at', 'o.created_by', 'o.grounding_height'
        ]
        ar_columns = [
            'ar_origin_latitude', 'ar_origin_longitude', 
            'ar_offset_x', 'ar_offset_y', 'ar_offset_z', 'ar_placement_timestamp'
        ]
        
        select_columns = base_columns.copy()
        for ar_col in ar_columns:
            if ar_col in column_names:
                select_columns.append(f'o.{ar_col}')
        
        select_columns.extend([
            'CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as collected',
            'f.found_by',
            'f.found_at'
        ])
        
        query = f'''
            SELECT 
                {', '.join(select_columns)}
            FROM objects o
            LEFT JOIN finds f ON o.id = f.object_id
        '''
        
        conditions = []
        params = []
        
        # Filter by location if provided
        if latitude is not None and longitude is not None:
            # Simple bounding box filter (approximate)
            # For production, use proper haversine formula
            lat_range = radius / 111000.0  # Rough conversion: 1 degree ≈ 111km
            lon_range = radius / (111000.0 * abs(math.cos(math.radians(latitude))))
            
            conditions.append('''
                (o.latitude BETWEEN ? AND ?) 
                AND (o.longitude BETWEEN ? AND ?)
            ''')
            params.extend([
                latitude - lat_range,
                latitude + lat_range,
                longitude - lon_range,
                longitude + lon_range
            ])
        
        # Filter out found objects unless include_found is true
        if not include_found:
            conditions.append('f.id IS NULL')
        
        if conditions:
            query += ' WHERE ' + ' AND '.join(conditions)
        
        query += ' ORDER BY o.created_at DESC'
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        conn.close()
        
        # Group by object_id to handle multiple finds (though we'll only show the first)
        objects_dict = {}
        for row in rows:
            obj_id = row['id']
            if obj_id not in objects_dict:
                obj_data = {
                    'id': row['id'],
                    'name': row['name'],
                    'type': row['type'],
                    'latitude': row['latitude'],
                    'longitude': row['longitude'],
                    'radius': row['radius'],
                    'created_at': row['created_at'],
                    'created_by': row['created_by'],
                    'grounding_height': row['grounding_height'],
                    'collected': bool(row['collected']),
                    'found_by': row['found_by'],
                    'found_at': row['found_at']
                }
                
                # Add AR columns if they exist
                for ar_col in ar_columns:
                    if ar_col in column_names and ar_col in row.keys():
                        obj_data[ar_col] = row[ar_col]
                    else:
                        obj_data[ar_col] = None
                
                objects_dict[obj_id] = obj_data
        
        return jsonify(list(objects_dict.values()))
    
    except Exception as e:
        # Ensure connection is closed on error
        try:
            conn.close()
        except:
            pass
        return jsonify({'error': str(e), 'type': type(e).__name__}), 500

@app.route('/api/objects/<object_id>', methods=['GET'])
def get_object(object_id: str):
    """Get a specific object by ID."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT 
            o.id,
            o.name,
            o.type,
            o.latitude,
            o.longitude,
            o.radius,
            o.created_at,
            o.created_by,
            o.grounding_height,
            o.ar_origin_latitude,
            o.ar_origin_longitude,
            o.ar_offset_x,
            o.ar_offset_y,
            o.ar_offset_z,
            o.ar_placement_timestamp,
            o.ar_anchor_transform,  -- Include AR anchor transform for precise positioning
            CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as collected,
            f.found_by,
            f.found_at
        FROM objects o
        LEFT JOIN finds f ON o.id = f.object_id
        WHERE o.id = ?
    ''', (object_id,))
    
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        return jsonify({'error': 'Object not found'}), 404
    
    return jsonify({
        'id': row['id'],
        'name': row['name'],
        'type': row['type'],
        'latitude': row['latitude'],
        'longitude': row['longitude'],
        'radius': row['radius'],
        'created_at': row['created_at'],
        'created_by': row['created_by'],
        'grounding_height': row['grounding_height'],
        'collected': bool(row['collected']),
        'found_by': row['found_by'],
        'found_at': row['found_at']
    })

@app.route('/api/objects', methods=['POST'])
def create_object():
    """Create a new object."""
    import time
    
    data = request.json
    
    required_fields = ['id', 'name', 'type', 'latitude', 'longitude', 'radius']
    for field in required_fields:
        if field not in data:
            return jsonify({'error': f'Missing required field: {field}'}), 400
    
    # Retry logic for database locking issues
    max_retries = 3
    retry_delay = 0.1  # 100ms between retries
    
    for attempt in range(max_retries):
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            
            try:
                cursor.execute('''
                    INSERT INTO objects (id, name, type, latitude, longitude, radius, created_at, created_by, grounding_height, ar_anchor_transform, ar_offset_x, ar_offset_y, ar_offset_z, ar_origin_latitude, ar_origin_longitude, ar_placement_timestamp)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (
                    data['id'],
                    data['name'],
                    data['type'],
                    data['latitude'],
                    data['longitude'],
                    data['radius'],
                    datetime.utcnow().isoformat(),
                    data.get('created_by', 'unknown'),
                    data.get('grounding_height'),  # Optional - can be None
                    data.get('ar_anchor_transform'),  # Optional AR anchor transform
                    data.get('ar_offset_x'),  # Optional AR offset X for <10cm accuracy
                    data.get('ar_offset_y'),  # Optional AR offset Y for <10cm accuracy
                    data.get('ar_offset_z'),  # Optional AR offset Z for <10cm accuracy
                    data.get('ar_origin_latitude'),  # Optional AR origin GPS latitude
                    data.get('ar_origin_longitude'),  # Optional AR origin GPS longitude
                    data.get('ar_placement_timestamp')  # Optional AR placement timestamp
                ))
                
                conn.commit()
                conn.close()
                break  # Success - exit retry loop
                
            except sqlite3.OperationalError as e:
                conn.rollback()
                conn.close()
                if 'locked' in str(e).lower() and attempt < max_retries - 1:
                    # Database is locked - retry after a short delay
                    print(f"⚠️ Database locked during create_object (attempt {attempt + 1}/{max_retries}), retrying in {retry_delay}s...")
                    time.sleep(retry_delay)
                    retry_delay *= 2  # Exponential backoff
                    continue
                else:
                    # Re-raise if it's not a locking issue or we've exhausted retries
                    raise
                    
        except sqlite3.Error as e:
            if 'conn' in locals():
                try:
                    conn.rollback()
                    conn.close()
                except:
                    pass
            if 'locked' in str(e).lower() and attempt < max_retries - 1:
                print(f"⚠️ Database locked during create_object (attempt {attempt + 1}/{max_retries}), retrying in {retry_delay}s...")
                time.sleep(retry_delay)
                retry_delay *= 2
                continue
            print(f"❌ Database error in create_object: {e}")
            return jsonify({'error': f'Database error: {str(e)}'}), 500
        except Exception as e:
            if 'conn' in locals():
                try:
                    conn.close()
                except:
                    pass
            print(f"❌ Unexpected error in create_object: {e}")
            import traceback
            traceback.print_exc()
            return jsonify({'error': f'Internal server error: {str(e)}'}), 500
    
    # Re-open connection to fetch the created object
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Get the created object to broadcast
        cursor.execute('''
            SELECT
                o.id,
                o.name,
                o.type,
                o.latitude,
                o.longitude,
                o.radius,
                o.created_at,
                o.created_by,
                o.grounding_height,
                o.ar_origin_latitude,
                o.ar_origin_longitude,
                o.ar_offset_x,
                o.ar_offset_y,
                o.ar_offset_z,
                o.ar_placement_timestamp,
                o.ar_anchor_transform,
                CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as collected,
                f.found_by,
                f.found_at
            FROM objects o
            LEFT JOIN finds f ON o.id = f.object_id
            WHERE o.id = ?
        ''', (data['id'],))
        
        row = cursor.fetchone()
        conn.close()
        
        if not row:
            return jsonify({'error': 'Failed to retrieve created object'}), 500
        
        # Broadcast new object to all connected clients
        if row:
            # Safely access row data, handling missing keys
            # sqlite3.Row objects support 'in' operator for key checking
            row_keys = list(row.keys()) if hasattr(row, 'keys') else []
            
            # Helper function to safely get row values
            def safe_get(key, default=None):
                return row[key] if key in row_keys else default
            
            socketio.emit('object_created', {
                'id': row['id'],
                'name': row['name'],
                'type': row['type'],
                'latitude': row['latitude'],
                'longitude': row['longitude'],
                'radius': row['radius'],
                'created_at': row['created_at'],
                'created_by': row['created_by'],
                'grounding_height': safe_get('grounding_height'),
                'ar_origin_latitude': safe_get('ar_origin_latitude'),
                'ar_origin_longitude': safe_get('ar_origin_longitude'),
                'ar_offset_x': safe_get('ar_offset_x'),
                'ar_offset_y': safe_get('ar_offset_y'),
                'ar_offset_z': safe_get('ar_offset_z'),
                'ar_placement_timestamp': safe_get('ar_placement_timestamp'),
                'ar_anchor_transform': safe_get('ar_anchor_transform'),  # Include AR anchor transform
                'collected': bool(safe_get('collected', 0)),
                'found_by': safe_get('found_by'),
                'found_at': safe_get('found_at')
            })
        
        return jsonify({
            'id': data['id'],
            'message': 'Object created successfully'
        }), 201
        
    except sqlite3.IntegrityError as e:
        conn.close()
        return jsonify({'error': 'Object with this ID already exists'}), 409
    except Exception as e:
        conn.close()
        import traceback
        error_trace = traceback.format_exc()
        print(f"❌ Error creating object: {str(e)}")
        print(f"Traceback: {error_trace}")
        return jsonify({'error': f'Internal server error: {str(e)}'}), 500

@app.route('/api/objects/<object_id>/found', methods=['POST'])
def mark_found(object_id: str):
    """Mark an object as found by a user."""
    try:
        data = request.json
        if not data:
            return jsonify({'error': 'No JSON data provided'}), 400
        
        found_by = data.get('found_by', 'unknown')
        if not found_by or found_by == 'unknown':
            return jsonify({'error': 'found_by field is required'}), 400
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        try:
            # Check if object exists
            cursor.execute('SELECT id FROM objects WHERE id = ?', (object_id,))
            if not cursor.fetchone():
                return jsonify({'error': 'Object not found'}), 404
            
            # MULTIPLE FINDS SUPPORT: Always create a new find record
            # This allows tracking multiple visits/scans of the same object
            # Previous logic only allowed one find per user per object
            
            # Record new find
            found_at = datetime.utcnow().isoformat()
            cursor.execute('''
                INSERT INTO finds (object_id, found_by, found_at)
                VALUES (?, ?, ?)
            ''', (object_id, found_by, found_at))
            
            conn.commit()
            
            # Broadcast object collected event to all connected clients
            try:
                socketio.emit('object_collected', {
                    'object_id': object_id,
                    'found_by': found_by,
                    'found_at': found_at
                })
            except Exception as emit_error:
                # Log but don't fail if WebSocket emit fails
                print(f"⚠️ Warning: Failed to emit object_collected event: {emit_error}")
            
            return jsonify({
                'object_id': object_id,
                'found_by': found_by,
                'message': 'Object marked as found'
            }), 200
            
        except sqlite3.IntegrityError as e:
            conn.rollback()
            error_msg = str(e)
            if 'UNIQUE' in error_msg or 'constraint' in error_msg.lower():
                return jsonify({'error': 'Object already found (constraint violation)'}), 409
            return jsonify({'error': f'Database constraint error: {error_msg}'}), 400
        except sqlite3.Error as e:
            conn.rollback()
            print(f"❌ Database error in mark_found: {e}")
            return jsonify({'error': f'Database error: {str(e)}'}), 500
        finally:
            conn.close()
            
    except Exception as e:
        print(f"❌ Unexpected error in mark_found: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Internal server error: {str(e)}'}), 500

@app.route('/api/objects/<object_id>', methods=['PUT', 'PATCH'])
def update_object(object_id: str):
    """Update an object's location (latitude/longitude)."""
    data = request.json
    
    if not data:
        return jsonify({'error': 'No data provided'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Build update query dynamically based on provided fields
    updates = []
    params = []
    
    if 'latitude' in data:
        updates.append('latitude = ?')
        params.append(data['latitude'])
    
    if 'longitude' in data:
        updates.append('longitude = ?')
        params.append(data['longitude'])
    
    if not updates:
        conn.close()
        return jsonify({'error': 'No valid fields to update'}), 400
    
    params.append(object_id)
    
    cursor.execute(f'''
        UPDATE objects
        SET {', '.join(updates)}
        WHERE id = ?
    ''', params)
    
    conn.commit()
    conn.close()
    
    return jsonify({'success': True, 'message': 'Object updated successfully'}), 200

@app.route('/api/objects/<object_id>/grounding', methods=['PUT', 'PATCH'])
def update_grounding(object_id: str):
    """Update the grounding height for an object."""
    data = request.json
    grounding_height = data.get('grounding_height')
    
    if grounding_height is None:
        return jsonify({'error': 'grounding_height is required'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if object exists
    cursor.execute('SELECT id FROM objects WHERE id = ?', (object_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'Object not found'}), 404
    
    # Update grounding height
    cursor.execute('''
        UPDATE objects 
        SET grounding_height = ?
        WHERE id = ?
    ''', (grounding_height, object_id))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'id': object_id,
        'grounding_height': grounding_height,
        'message': 'Grounding height updated successfully'
    })

@app.route('/api/objects/<object_id>/ar-offset', methods=['PUT', 'PATCH'])
def update_ar_offset(object_id: str):
    """Update the AR offset coordinates for an object (cm-level precision for indoor placement)."""
    data = request.json
    
    required_fields = ['ar_origin_latitude', 'ar_origin_longitude', 'ar_offset_x', 'ar_offset_y', 'ar_offset_z']
    for field in required_fields:
        if field not in data:
            return jsonify({'error': f'Missing required field: {field}'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if object exists
    cursor.execute('SELECT id FROM objects WHERE id = ?', (object_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'Object not found'}), 404
    
    # Update AR offset coordinates (REAL type supports cm-level precision)
    cursor.execute('''
        UPDATE objects 
        SET ar_origin_latitude = ?,
            ar_origin_longitude = ?,
            ar_offset_x = ?,
            ar_offset_y = ?,
            ar_offset_z = ?,
            ar_placement_timestamp = ?
        WHERE id = ?
    ''', (
        data['ar_origin_latitude'],
        data['ar_origin_longitude'],
        data['ar_offset_x'],
        data['ar_offset_y'],
        data['ar_offset_z'],
        data.get('ar_placement_timestamp', datetime.utcnow().isoformat()),
        object_id
    ))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'id': object_id,
        'ar_origin_latitude': data['ar_origin_latitude'],
        'ar_origin_longitude': data['ar_origin_longitude'],
        'ar_offset_x': data['ar_offset_x'],
        'ar_offset_y': data['ar_offset_y'],
        'ar_offset_z': data['ar_offset_z'],
        'message': 'AR offset coordinates updated successfully'
    })

@app.route('/api/objects/<object_id>/found', methods=['DELETE'])
def unmark_found(object_id: str):
    """Unmark an object as found (for testing/reset)."""
    import time
    
    # Retry logic for database locking issues
    max_retries = 3
    retry_delay = 0.1  # 100ms between retries
    
    for attempt in range(max_retries):
        try:
            # Check if object exists
            conn = get_db_connection()
            cursor = conn.cursor()
            
            try:
                cursor.execute('SELECT id FROM objects WHERE id = ?', (object_id,))
                if not cursor.fetchone():
                    conn.close()
                    return jsonify({'error': 'Object not found'}), 404
                
                # Delete find record if it exists
                cursor.execute('DELETE FROM finds WHERE object_id = ?', (object_id,))
                deleted = cursor.rowcount
                
                conn.commit()
                conn.close()
                
                # Broadcast object uncollected event to all connected clients
                # Do this even if no record was deleted (object was already unfound)
                try:
                    socketio.emit('object_uncollected', {
                        'object_id': object_id
                    })
                except Exception as emit_error:
                    # Log but don't fail if WebSocket emit fails
                    print(f"⚠️ Warning: Failed to emit object_uncollected event: {emit_error}")
                
                if deleted == 0:
                    # Object was already unfound - return success anyway (idempotent operation)
                    return jsonify({
                        'object_id': object_id,
                        'message': 'Object was already unfound'
                    }), 200
                
                return jsonify({
                    'object_id': object_id,
                    'message': 'Object unmarked as found'
                }), 200
                
            except sqlite3.OperationalError as e:
                conn.rollback()
                conn.close()
                if 'locked' in str(e).lower() and attempt < max_retries - 1:
                    # Database is locked - retry after a short delay
                    print(f"⚠️ Database locked (attempt {attempt + 1}/{max_retries}), retrying in {retry_delay}s...")
                    time.sleep(retry_delay)
                    retry_delay *= 2  # Exponential backoff
                    continue
                else:
                    # Re-raise if it's not a locking issue or we've exhausted retries
                    raise
                    
        except sqlite3.Error as e:
            if 'conn' in locals():
                try:
                    conn.rollback()
                    conn.close()
                except:
                    pass
            if 'locked' in str(e).lower() and attempt < max_retries - 1:
                print(f"⚠️ Database locked (attempt {attempt + 1}/{max_retries}), retrying in {retry_delay}s...")
                time.sleep(retry_delay)
                retry_delay *= 2
                continue
            print(f"❌ Database error in unmark_found: {e}")
            return jsonify({'error': f'Database error: {str(e)}'}), 500
        except Exception as e:
            if 'conn' in locals():
                try:
                    conn.close()
                except:
                    pass
            print(f"❌ Unexpected error in unmark_found: {e}")
            import traceback
            traceback.print_exc()
            return jsonify({'error': f'Internal server error: {str(e)}'}), 500
    
    # If we get here, all retries failed
    return jsonify({'error': 'Database operation failed after retries'}), 500

@app.route('/api/users/<user_id>/finds', methods=['GET'])
def get_user_finds(user_id: str):
    """Get all objects found by a specific user."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT 
            o.id,
            o.name,
            o.type,
            o.latitude,
            o.longitude,
            f.found_at
        FROM finds f
        JOIN objects o ON f.object_id = o.id
        WHERE f.found_by = ?
        ORDER BY f.found_at DESC
    ''', (user_id,))
    
    rows = cursor.fetchall()
    conn.close()
    
    finds = [{
        'id': row['id'],
        'name': row['name'],
        'type': row['type'],
        'latitude': row['latitude'],
        'longitude': row['longitude'],
        'found_at': row['found_at']
    } for row in rows]
    
    return jsonify(finds)

@app.route('/api/players', methods=['GET'])
def get_all_players():
    """Get all players with their find counts."""
    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Get all players with their find counts
        cursor.execute('''
            SELECT 
                p.device_uuid,
                p.player_name,
                p.created_at,
                p.updated_at,
                COUNT(f.id) as find_count
            FROM players p
            LEFT JOIN finds f ON p.device_uuid = f.found_by
            GROUP BY p.device_uuid, p.player_name, p.created_at, p.updated_at
            ORDER BY find_count DESC, p.updated_at DESC
        ''')
        
        rows = cursor.fetchall()
        
        players = [{
            'device_uuid': row['device_uuid'],
            'player_name': row['player_name'],
            'created_at': row['created_at'],
            'updated_at': row['updated_at'],
            'find_count': row['find_count']
        } for row in rows]
        
        return jsonify(players)
    except sqlite3.OperationalError as e:
        error_msg = f"Database error in /api/players: {str(e)}"
        print(f"❌ {error_msg}")
        print(traceback.format_exc())
        return jsonify({'error': 'Database operation failed', 'details': str(e)}), 500
    except sqlite3.Error as e:
        error_msg = f"SQLite error in /api/players: {str(e)}"
        print(f"❌ {error_msg}")
        print(traceback.format_exc())
        return jsonify({'error': 'Database error', 'details': str(e)}), 500
    except Exception as e:
        error_msg = f"Unexpected error in /api/players: {str(e)}"
        print(f"❌ {error_msg}")
        print(traceback.format_exc())
        return jsonify({'error': 'Internal server error', 'details': str(e)}), 500
    finally:
        if conn:
            try:
                conn.close()
            except:
                pass

@app.route('/api/players/<device_uuid>', methods=['GET'])
def get_player(device_uuid: str):
    """Get player name for a device UUID."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT device_uuid, player_name, created_at, updated_at
        FROM players
        WHERE device_uuid = ?
    ''', (device_uuid,))
    
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        return jsonify({'error': 'Player not found'}), 404
    
    return jsonify({
        'device_uuid': row['device_uuid'],
        'player_name': row['player_name'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at']
    })

@app.route('/api/users/<device_uuid>/location', methods=['POST', 'PUT'])
def update_user_location(device_uuid: str):
    """Update the current location of a user (for web map display)."""
    data = request.json
    
    if not data or 'latitude' not in data or 'longitude' not in data:
        return jsonify({'error': 'Missing required fields: latitude, longitude'}), 400
    
    latitude = float(data['latitude'])
    longitude = float(data['longitude'])
    accuracy = data.get('accuracy')  # Optional GPS accuracy in meters
    heading = data.get('heading')  # Optional heading in degrees
    ar_offset_x = data.get('ar_offset_x')  # Optional AR offset X in meters
    ar_offset_y = data.get('ar_offset_y')  # Optional AR offset Y in meters
    ar_offset_z = data.get('ar_offset_z')  # Optional AR offset Z in meters
    
    # Store user location with timestamp (in-memory)
    updated_at = datetime.utcnow().isoformat()
    user_locations[device_uuid] = {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'heading': heading,
        'ar_offset_x': ar_offset_x,
        'ar_offset_y': ar_offset_y,
        'ar_offset_z': ar_offset_z,
        'updated_at': updated_at
    }
    
    # Persist last known location to the database so it survives server restarts
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('''
            INSERT INTO user_last_locations (device_uuid, latitude, longitude, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(device_uuid) DO UPDATE SET
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                updated_at = excluded.updated_at
        ''', (device_uuid, latitude, longitude, updated_at))
        conn.commit()
        conn.close()
    except Exception as e:
        # Don't fail the API call if persistence fails; just log the error
        print(f"⚠️ Failed to persist user last location for {device_uuid}: {e}")

    # Log AR-enhanced location if available
    if ar_offset_x is not None:
        print(f"📍 User location updated (AR-enhanced): {device_uuid[:8]}... at ({latitude:.6f}, {longitude:.6f}), AR offset: ({ar_offset_x:.3f}, {ar_offset_y:.3f}, {ar_offset_z:.3f})m")
    else:
        print(f"📍 User location updated: {device_uuid[:8]}... at ({latitude:.6f}, {longitude:.6f})")
    
    # Log total active users
    print(f"   Total users in memory: {len(user_locations)}")
    print(f"   User UUIDs: {list(user_locations.keys())}")
    
    # Broadcast location update via WebSocket
    socketio.emit('user_location_updated', {
        'device_uuid': device_uuid,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'heading': heading,
        'ar_offset_x': ar_offset_x,
        'ar_offset_y': ar_offset_y,
        'ar_offset_z': ar_offset_z,
        'updated_at': user_locations[device_uuid]['updated_at']
    })
    
    return jsonify({
        'device_uuid': device_uuid,
        'latitude': latitude,
        'longitude': longitude,
        'message': 'Location updated successfully'
    }), 200

@app.route('/api/map/default_center', methods=['GET'])
def get_map_default_center():
    """
    Get the default map center based on the most recent known user location.
    Falls back to 204 No Content if no locations have ever been recorded.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute('''
        SELECT latitude, longitude, updated_at
        FROM user_last_locations
        ORDER BY updated_at DESC
        LIMIT 1
    ''')
    row = cursor.fetchone()
    conn.close()

    if not row:
        # No known locations yet
        return jsonify({'latitude': None, 'longitude': None, 'updated_at': None}), 200

    return jsonify({
        'latitude': row['latitude'],
        'longitude': row['longitude'],
        'updated_at': row['updated_at']
    }), 200

@app.route('/api/users/locations', methods=['GET'])
def get_all_user_locations():
    """Get all current user locations (for web map display)."""
    # Optionally filter out stale locations (older than 5 minutes)
    from datetime import timezone
    cutoff_time = datetime.utcnow().replace(tzinfo=timezone.utc)
    active_locations = {}
    
    for device_uuid, location_data in user_locations.items():
        try:
            # Parse the timestamp - handle both 'Z' suffix and timezone-aware formats
            updated_at_str = location_data['updated_at']
            if updated_at_str.endswith('Z'):
                updated_at_str = updated_at_str.replace('Z', '+00:00')
            
            updated_at = datetime.fromisoformat(updated_at_str)
            # Make both datetimes timezone-aware for comparison
            if updated_at.tzinfo is None:
                # If no timezone, assume UTC
                updated_at = updated_at.replace(tzinfo=timezone.utc)
            
            age_seconds = (cutoff_time - updated_at).total_seconds()
            
            # Only include locations updated in the last 5 minutes
            if age_seconds < 300:  # 5 minutes
                active_locations[device_uuid] = location_data
        except Exception as e:
            # Log parsing errors but continue processing other locations
            print(f"⚠️ Error parsing location timestamp for {device_uuid}: {e}")
            # Include the location anyway if we can't parse the timestamp
            active_locations[device_uuid] = location_data
    
    print(f"📍 Returning {len(active_locations)} active user locations (out of {len(user_locations)} total)")
    if active_locations:
        print(f"   Active device UUIDs: {list(active_locations.keys())}")
    return jsonify(active_locations), 200

@app.route('/api/players/<device_uuid>', methods=['POST', 'PUT'])
def create_or_update_player(device_uuid: str):
    """Create or update player name for a device UUID."""
    import time
    import sqlite3
    
    data = request.json
    
    if not data or 'player_name' not in data:
        return jsonify({'error': 'Missing required field: player_name'}), 400
    
    player_name = data['player_name'].strip()
    if not player_name:
        return jsonify({'error': 'player_name cannot be empty'}), 400
    
    # Retry logic for database locking (up to 3 attempts)
    max_retries = 3
    retry_delay = 0.1  # 100ms between retries
    
    for attempt in range(max_retries):
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            
            now = datetime.utcnow().isoformat()
            
            # Check if player exists (device UUID is the unique identifier)
            cursor.execute('SELECT device_uuid FROM players WHERE device_uuid = ?', (device_uuid,))
            current_player = cursor.fetchone()
            
            if current_player:
                # Update existing player (device UUID is unique, names can be duplicated)
                cursor.execute('''
                    UPDATE players
                    SET player_name = ?, updated_at = ?
                    WHERE device_uuid = ?
                ''', (player_name, now, device_uuid))
            else:
                # Create new player (device UUID is the primary key, ensures uniqueness)
                cursor.execute('''
                    INSERT INTO players (device_uuid, player_name, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                ''', (device_uuid, player_name, now, now))
            
            conn.commit()
            
            # Get the updated/created player
            cursor.execute('''
                SELECT device_uuid, player_name, created_at, updated_at
                FROM players
                WHERE device_uuid = ?
            ''', (device_uuid,))
            
            row = cursor.fetchone()
            conn.close()
            
            if not row:
                return jsonify({'error': 'Failed to retrieve player after creation/update'}), 500
            
            return jsonify({
                'device_uuid': row['device_uuid'],
                'player_name': row['player_name'],
                'created_at': row['created_at'],
                'updated_at': row['updated_at']
            }), 200
            
        except sqlite3.IntegrityError as e:
            # Handle UNIQUE constraint violations
            error_msg = str(e).lower()
            if 'unique constraint failed' in error_msg and 'player_name' in error_msg:
                # UNIQUE constraint on player_name exists but shouldn't
                # Try to remove it and retry (only on first attempt to avoid infinite loop)
                if attempt == 0:
                    try:
                        print("⚠️ UNIQUE constraint on player_name detected - attempting to remove it")
                        # Recreate table without UNIQUE constraint
                        cursor.execute('''
                            CREATE TABLE IF NOT EXISTS players_new (
                                device_uuid TEXT PRIMARY KEY,
                                player_name TEXT NOT NULL,
                                created_at TEXT NOT NULL,
                                updated_at TEXT NOT NULL
                            )
                        ''')
                        # Copy data
                        cursor.execute('''
                            INSERT INTO players_new (device_uuid, player_name, created_at, updated_at)
                            SELECT device_uuid, player_name, created_at, updated_at FROM players
                        ''')
                        # Drop old table
                        cursor.execute('DROP TABLE players')
                        # Rename new table
                        cursor.execute('ALTER TABLE players_new RENAME TO players')
                        # Recreate index
                        cursor.execute('''
                            CREATE INDEX IF NOT EXISTS idx_player_name ON players(player_name)
                        ''')
                        conn.commit()
                        conn.close()
                        print("✅ Removed UNIQUE constraint on player_name - retrying operation")
                        # Retry the operation (will get new connection on next iteration)
                        continue
                    except Exception as fix_error:
                        print(f"❌ Failed to remove UNIQUE constraint: {fix_error}")
                        conn.close()
                        return jsonify({'error': f'UNIQUE constraint on player_name exists. Please contact administrator to remove it. Error: {str(e)}'}), 500
                else:
                    # Already tried to fix, return error
                    conn.close()
                    return jsonify({'error': f'UNIQUE constraint failed: player_name. This constraint should not exist. Error: {str(e)}'}), 500
            else:
                # Other integrity error
                print(f"❌ Integrity error in create_or_update_player: {e}")
                conn.close()
                return jsonify({'error': f'Database integrity error: {str(e)}'}), 500
        except sqlite3.OperationalError as e:
            if 'database is locked' in str(e).lower() and attempt < max_retries - 1:
                # Database is locked, wait and retry
                time.sleep(retry_delay * (attempt + 1))  # Exponential backoff
                continue
            else:
                # Re-raise if it's not a locking issue or we've exhausted retries
                print(f"❌ Database error in create_or_update_player: {e}")
                return jsonify({'error': f'Database error: {str(e)}'}), 500
        except Exception as e:
            print(f"❌ Error in create_or_update_player: {e}")
            import traceback
            traceback.print_exc()
            return jsonify({'error': f'Internal server error: {str(e)}'}), 500

@app.route('/api/players/<device_uuid>', methods=['DELETE'])
def delete_player(device_uuid: str):
    """Delete a player and all their finds."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if player exists
    cursor.execute('SELECT device_uuid FROM players WHERE device_uuid = ?', (device_uuid,))
    player = cursor.fetchone()
    
    if not player:
        conn.close()
        return jsonify({'error': 'Player not found'}), 404
    
    # Delete all finds by this player (this will make objects unfound again)
    cursor.execute('DELETE FROM finds WHERE found_by = ?', (device_uuid,))
    finds_deleted = cursor.rowcount
    
    # Delete the player
    cursor.execute('DELETE FROM players WHERE device_uuid = ?', (device_uuid,))
    
    conn.commit()
    conn.close()
    
    # Broadcast object uncollected events for all objects that were found by this player
    # We need to get the object IDs first, but we already deleted them, so we'll just refresh
    # The frontend will handle the refresh
    
    return jsonify({
        'message': f'Player deleted successfully. {finds_deleted} find(s) removed.',
        'finds_deleted': finds_deleted
    }), 200

@app.route('/api/players/<device_uuid>/kick', methods=['POST'])
def kick_player(device_uuid: str):
    """Kick/disconnect a player by closing their WebSocket connection."""
    # Find all sessions for this device
    target_sessions = client_sessions.get(device_uuid, set())
    
    if not target_sessions:
        return jsonify({
            'message': f'Player {device_uuid[:8]}... is not connected',
            'kicked': False
        }), 200
    
    # Disconnect all sessions for this device
    disconnected_count = 0
    for session_id in list(target_sessions):
        try:
            socketio.server.disconnect(session_id)
            disconnected_count += 1
        except Exception as e:
            print(f"⚠️ Error disconnecting session {session_id[:8]}...: {e}")
    
    # Clean up tracking
    for session_id in list(target_sessions):
        connected_clients.pop(session_id, None)
        client_sessions[device_uuid].discard(session_id)
    
    if not client_sessions[device_uuid]:
        del client_sessions[device_uuid]
    
    print(f"👢 Kicked player {device_uuid[:8]}... ({disconnected_count} session(s) disconnected)")
    
    return jsonify({
        'message': f'Player kicked successfully. {disconnected_count} connection(s) closed.',
        'kicked': True,
        'sessions_disconnected': disconnected_count
    }), 200

@app.route('/api/stats', methods=['GET'])
def get_stats():
    """Get statistics about objects and finds."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Total objects
    cursor.execute('SELECT COUNT(*) as count FROM objects')
    total_objects = cursor.fetchone()['count']
    
    # Found objects
    cursor.execute('SELECT COUNT(DISTINCT object_id) as count FROM finds')
    found_objects = cursor.fetchone()['count']
    
    # Total finds
    cursor.execute('SELECT COUNT(*) as count FROM finds')
    total_finds = cursor.fetchone()['count']
    
    # Top finders - include all players, even those with 0 finds
    # Device UUID is the unique identifier, player names can be duplicated
    # First get all players
    cursor.execute('''
        SELECT device_uuid, player_name
        FROM players
    ''')
    all_players = {row['device_uuid']: row['player_name'] for row in cursor.fetchall()}
    
    # Create reverse lookup: player name -> device UUID (for legacy finds that use names)
    name_to_uuid = {}
    for uuid, name in all_players.items():
        if name:
            # Handle case-insensitive matching
            name_lower = name.lower()
            if name_lower not in name_to_uuid:
                name_to_uuid[name_lower] = []
            name_to_uuid[name_lower].append((uuid, name))
    
    # Get find counts - group by found_by (which might be UUID or player name)
    cursor.execute('''
        SELECT 
            f.found_by,
            COUNT(*) as count
        FROM finds f
        GROUP BY f.found_by
    ''')
    find_counts_raw = {row['found_by']: row['count'] for row in cursor.fetchall()}
    
    # Normalize find counts by device UUID
    # Handle both cases: found_by is UUID or found_by is player name (legacy)
    find_counts = {}
    for found_by, count in find_counts_raw.items():
        # Check if found_by is a device UUID (in players table)
        if found_by in all_players:
            # It's a UUID - use it directly
            find_counts[found_by] = find_counts.get(found_by, 0) + count
        else:
            # It might be a player name (legacy data from before we used UUIDs)
            # Try to find matching UUID(s)
            found_by_lower = found_by.lower()
            if found_by_lower in name_to_uuid:
                matching_uuids = name_to_uuid[found_by_lower]
                if len(matching_uuids) == 1:
                    # Only one player with this name, assign finds to them
                    uuid = matching_uuids[0][0]
                    find_counts[uuid] = find_counts.get(uuid, 0) + count
                else:
                    # Multiple players with same name - can't determine which one
                    # Skip this find or assign to first one (but this causes issues)
                    # For now, assign to first one but log a warning
                    uuid = matching_uuids[0][0]
                    find_counts[uuid] = find_counts.get(uuid, 0) + count
                    print(f"⚠️  Warning: Found legacy find with name '{found_by}' matching {len(matching_uuids)} players. Assigned to {uuid[:8]}")
            else:
                # Unknown found_by - might be old UUID format, add as-is but don't show in leaderboard
                # (we'll only show players from the players table)
                pass
    
    # Check for duplicate player names to decide if we need to show UUIDs
    player_name_counts = {}
    for player_name in all_players.values():
        if player_name:
            player_name_counts[player_name] = player_name_counts.get(player_name, 0) + 1
    has_duplicate_names = any(count > 1 for count in player_name_counts.values())
    
    # Combine: all players with their find counts (0 if no finds)
    # Each device UUID should appear only once
    all_finders = []
    for device_uuid, player_name in all_players.items():
        count = find_counts.get(device_uuid, 0)
        # If there are duplicate names, append short UUID to distinguish
        display_name = player_name or device_uuid
        if has_duplicate_names and player_name and player_name_counts.get(player_name, 0) > 1:
            display_name = f"{player_name} ({device_uuid[:8]})"
        all_finders.append({
            'user': display_name,
            'count': count,
            'device_uuid': device_uuid
        })
    
    # Sort by count descending, then by name
    all_finders.sort(key=lambda x: (-x['count'], x['user']))
    
    # Limit to top 50 (or all if less than 50)
    top_finders = all_finders[:50]
    
    # Count objects by type
    cursor.execute('''
        SELECT type, COUNT(*) as count
        FROM objects
        GROUP BY type
        ORDER BY type
    ''')
    type_counts = {row['type']: row['count'] for row in cursor.fetchall()}
    
    conn.close()
    
    response = jsonify({
        'total_objects': total_objects,
        'found_objects': found_objects,
        'unfound_objects': total_objects - found_objects,
        'total_finds': total_finds,
        'top_finders': top_finders,
        'counts_by_type': type_counts
    })
    
    # Prevent caching of stats endpoint
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    
    return response

@app.route('/api/finds/reset', methods=['POST'])
def reset_all_finds():
    """Reset all objects to unfound status by clearing all finds."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Count finds before deletion
    cursor.execute('SELECT COUNT(*) as count FROM finds')
    finds_count = cursor.fetchone()['count']
    
    # Delete all finds
    cursor.execute('DELETE FROM finds')
    deleted_count = cursor.rowcount
    
    conn.commit()
    conn.close()
    
    # Broadcast reset event to all connected clients
    socketio.emit('all_finds_reset', {
        'message': 'All objects have been reset to unfound status',
        'finds_removed': deleted_count
    })
    
    return jsonify({
        'message': 'All finds have been reset',
        'finds_removed': deleted_count
    }), 200

@app.route('/api/objects/<object_id>', methods=['DELETE'])
def delete_object(object_id: str):
    """Delete an object and all associated finds."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if object exists
    cursor.execute('SELECT id FROM objects WHERE id = ?', (object_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'Object not found'}), 404
    
    # Delete associated finds first (foreign key constraint)
    cursor.execute('DELETE FROM finds WHERE object_id = ?', (object_id,))
    finds_deleted = cursor.rowcount
    
    # Delete the object
    cursor.execute('DELETE FROM objects WHERE id = ?', (object_id,))
    object_deleted = cursor.rowcount
    
    conn.commit()
    conn.close()
    
    if object_deleted == 0:
        return jsonify({'error': 'Failed to delete object'}), 500
    
    # Broadcast object deleted event to all connected clients
    socketio.emit('object_deleted', {
        'object_id': object_id
    })
    
    return jsonify({
        'object_id': object_id,
        'message': 'Object deleted successfully',
        'finds_deleted': finds_deleted
    }), 200

@app.route('/admin')
@app.route('/admin/')
def admin_ui():
    """Serve the admin web UI."""
    response = send_from_directory(os.path.dirname(__file__), 'admin.html')
    # Disable caching for admin panel during development
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    return response

@app.route('/nfc/<nfc_id>')
def nfc_details(nfc_id: str):
    """Serve the NFC loot details page."""
    response = send_from_directory(os.path.dirname(__file__), 'nfc_details.html')
    # Disable caching for NFC details page during development
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    return response

@app.route('/api/nfc/<nfc_id>', methods=['GET'])
def get_nfc_details(nfc_id: str):
    """Get detailed information about a loot item by NFC ID.

    Supports multiple ID formats:
    - Full UUID (e.g., '0B8DA041-AA9F-45B5-B481-EB063CB8A50C')
    - Full NFC object ID (e.g., 'nfc_04a9ab961e6180_1764712047')
    - Short NFC chip UID (e.g., '69423A79' or '04a9ab961e6180')
    """
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        # Normalize the NFC ID to lowercase for case-insensitive matching
        nfc_id_lower = nfc_id.lower()

        # Try to find the object by:
        # 1. Exact match on object ID (handles full UUID or full NFC object ID)
        # 2. Pattern match for NFC chip UID (handles short chip IDs like '69423A79')
        cursor.execute('''
            SELECT
                o.id,
                o.name,
                o.type,
                o.latitude,
                o.longitude,
                o.radius,
                o.created_at,
                o.created_by,
                o.grounding_height,
                o.ar_origin_latitude,
                o.ar_origin_longitude,
                o.ar_offset_x,
                o.ar_offset_y,
                o.ar_offset_z,
                o.ar_placement_timestamp,
                o.ar_anchor_transform
            FROM objects o
            WHERE LOWER(o.id) = ?
               OR LOWER(o.id) LIKE 'nfc_' || ? || '_%'
            ORDER BY o.created_at DESC
            LIMIT 1
        ''', (nfc_id_lower, nfc_id_lower))

        obj_row = cursor.fetchone()

        if not obj_row:
            conn.close()
            return jsonify({'error': 'Object not found'}), 404

        # Get player who placed it
        placer_name = 'Unknown'
        if obj_row['created_by']:
            cursor.execute('SELECT player_name FROM players WHERE device_uuid = ?', (obj_row['created_by'],))
            placer_row = cursor.fetchone()
            if placer_row:
                placer_name = placer_row['player_name']

        # Get all finds for this object (use the actual object ID from the matched row)
        cursor.execute('''
            SELECT
                f.id,
                f.found_by,
                f.found_at,
                p.player_name
            FROM finds f
            LEFT JOIN players p ON f.found_by = p.device_uuid
            WHERE f.object_id = ?
            ORDER BY f.found_at DESC
        ''', (obj_row['id'],))

        finds_rows = cursor.fetchall()
        finds_count = len(finds_rows)

        # Build finds list with player names
        finds_list = []
        for find_row in finds_rows:
            finds_list.append({
                'id': find_row['id'],
                'found_by': find_row['found_by'],
                'found_at': find_row['found_at'],
                'player_name': find_row['player_name'] or 'Unknown Player'
            })

        conn.close()

        return jsonify({
            'id': obj_row['id'],
            'name': obj_row['name'],
            'type': obj_row['type'],
            'latitude': obj_row['latitude'],
            'longitude': obj_row['longitude'],
            'radius': obj_row['radius'],
            'created_at': obj_row['created_at'],
            'created_by': obj_row['created_by'],
            'placed_by_name': placer_name,
            'grounding_height': obj_row['grounding_height'],
            'ar_origin_latitude': obj_row['ar_origin_latitude'],
            'ar_origin_longitude': obj_row['ar_origin_longitude'],
            'ar_offset_x': obj_row['ar_offset_x'],
            'ar_offset_y': obj_row['ar_offset_y'],
            'ar_offset_z': obj_row['ar_offset_z'],
            'ar_placement_timestamp': obj_row['ar_placement_timestamp'],
            'ar_anchor_transform': obj_row['ar_anchor_transform'],
            'collection_count': finds_count,
            'finds': finds_list
        })

    except Exception as e:
        conn.close()
        return jsonify({'error': str(e)}), 500

@app.route('/api/server-info', methods=['GET'])
def get_server_info():
    """Get server network information including IP address."""
    # Log access for debugging
    print(f"📡 Server info requested from {request.remote_addr} (Host: {request.host})")

    port = int(os.environ.get('PORT', 5001))
    # Use get_local_ip() which checks HOST_IP env var first for consistency
    # This ensures QR code and server-info always show the same IP
    try:
        local_ip = get_local_ip()
    except RuntimeError as e:
        return jsonify({
            'error': str(e),
            'status': 'error',
            'message': 'HOST_IP environment variable is required for server operation'
        }), 500

    # Get the host from the request to determine what URL was used
    host = request.host.split(':')[0] if ':' in request.host else request.host

    # Always use the network IP for the server URL (not localhost)
    server_url = f'http://{local_ip}:{port}'

    return jsonify({
        'local_ip': local_ip,
        'host': host,
        'port': port,
        'server_url': server_url,
        'request_host': request.host,
        'remote_addr': request.remote_addr
    })

@app.route('/api/debug/connection-test', methods=['GET'])
def connection_test():
    """Debug endpoint to test connectivity from client."""
    import platform
    
    def get_all_network_interfaces():
        """Get all network interfaces and their IPs."""
        interfaces = []
        try:
            import netifaces
            for interface in netifaces.interfaces():
                addrs = netifaces.ifaddresses(interface)
                if netifaces.AF_INET in addrs:
                    for addr_info in addrs[netifaces.AF_INET]:
                        ip = addr_info.get('addr')
                        if ip and not ip.startswith('127.'):
                            interfaces.append({
                                'interface': interface,
                                'ip': ip,
                                'netmask': addr_info.get('netmask')
                            })
        except ImportError:
            # Fallback if netifaces not available
            try:
                import subprocess
                result = subprocess.run(['ifconfig'], capture_output=True, text=True)
                # Simple parsing (basic fallback)
                for line in result.stdout.split('\n'):
                    if 'inet ' in line and '127.0.0.1' not in line:
                        parts = line.strip().split()
                        if len(parts) >= 2:
                            ip = parts[1]
                            if not ip.startswith('127.'):
                                interfaces.append({
                                    'interface': 'unknown',
                                    'ip': ip,
                                    'netmask': None
                                })
            except:
                pass
        
        return interfaces
    
    port = int(os.environ.get('PORT', 5001))
    try:
        local_ip = get_local_ip()
    except RuntimeError as e:
        return jsonify({
            'status': 'error',
            'message': 'Connection test failed - HOST_IP not configured',
            'error': str(e),
            'server_info': {
                'detected_ip': None,
                'port': port,
                'host': request.host,
                'remote_addr': request.remote_addr,
                'user_agent': request.headers.get('User-Agent', 'Unknown'),
                'server_url': None,
                'platform': platform.system(),
                'python_version': platform.python_version()
            },
            'network_interfaces': get_all_network_interfaces(),
            'timestamp': datetime.utcnow().isoformat()
        }), 500

    return jsonify({
        'status': 'success',
        'message': 'Connection test successful!',
        'server_info': {
            'detected_ip': local_ip,
            'port': port,
            'host': request.host,
            'remote_addr': request.remote_addr,
            'user_agent': request.headers.get('User-Agent', 'Unknown'),
            'server_url': f'http://{local_ip}:{port}',
            'platform': platform.system(),
            'python_version': platform.python_version()
        },
        'network_interfaces': get_all_network_interfaces(),
        'timestamp': datetime.utcnow().isoformat()
    })

@app.route('/api/debug/test-port', methods=['GET'])
def test_port():
    """Test if a specific port is reachable from the server's perspective."""
    import socket
    
    port = request.args.get('port', type=int)
    host = request.args.get('host', '127.0.0.1')
    timeout = request.args.get('timeout', type=float, default=3.0)
    
    if not port:
        return jsonify({'error': 'port parameter required'}), 400
    
    result = {
        'host': host,
        'port': port,
        'reachable': False,
        'error': None,
        'test_timestamp': datetime.utcnow().isoformat()
    }
    
    try:
        # Test TCP connectivity
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        connection_result = sock.connect_ex((host, port))
        sock.close()
        
        if connection_result == 0:
            result['reachable'] = True
            result['message'] = f'Port {port} is reachable on {host}'
        else:
            result['reachable'] = False
            result['error'] = f'Connection refused (error code: {connection_result})'
            result['message'] = f'Port {port} is not reachable on {host}'
            
    except socket.timeout:
        result['error'] = 'Connection timeout'
        result['message'] = f'Port {port} test timed out after {timeout}s'
    except socket.gaierror as e:
        result['error'] = f'DNS resolution failed: {str(e)}'
        result['message'] = f'Could not resolve host {host}'
    except Exception as e:
        result['error'] = str(e)
        result['message'] = f'Error testing port {port}: {str(e)}'
    
    return jsonify(result)

@app.route('/api/debug/test-ports', methods=['GET'])
def test_ports():
    """Test multiple ports for connectivity."""
    ports_str = request.args.get('ports', '5001,5000,8080,3000,8000')
    try:
        default_host = get_local_ip()
    except RuntimeError as e:
        return jsonify({
            'error': str(e),
            'message': 'Cannot test ports - HOST_IP not configured'
        }), 500

    host = request.args.get('host', default_host)
    ports = [int(p.strip()) for p in ports_str.split(',') if p.strip().isdigit()]
    
    results = []
    for port in ports:
        # Use internal test
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2.0)
        try:
            connection_result = sock.connect_ex((host, port))
            sock.close()
            results.append({
                'port': port,
                'reachable': connection_result == 0,
                'error': None if connection_result == 0 else f'Connection refused (code: {connection_result})'
            })
        except Exception as e:
            results.append({
                'port': port,
                'reachable': False,
                'error': str(e)
            })
    
    return jsonify({
        'host': host,
        'tested_ports': results,
        'timestamp': datetime.utcnow().isoformat()
    })

@app.route('/api/debug/network-info', methods=['GET'])
def network_info():
    """Get detailed network information for debugging."""
    def get_all_ips():
        """Get all IP addresses on all interfaces."""
        ips = []
        try:
            import netifaces
            for interface in netifaces.interfaces():
                addrs = netifaces.ifaddresses(interface)
                if netifaces.AF_INET in addrs:
                    for addr_info in addrs[netifaces.AF_INET]:
                        ip = addr_info.get('addr')
                        if ip:
                            ips.append({
                                'interface': interface,
                                'ip': ip,
                                'netmask': addr_info.get('netmask'),
                                'broadcast': addr_info.get('broadcast')
                            })
        except ImportError:
            # Fallback method
            try:
                import subprocess
                result = subprocess.run(['ifconfig'], capture_output=True, text=True, timeout=5)
                current_interface = None
                for line in result.stdout.split('\n'):
                    if ':' in line and not line.startswith(' '):
                        current_interface = line.split(':')[0]
                    elif 'inet ' in line:
                        parts = line.strip().split()
                        if len(parts) >= 2:
                            ip = parts[1]
                            ips.append({
                                'interface': current_interface or 'unknown',
                                'ip': ip,
                                'netmask': None,
                                'broadcast': None
                            })
            except Exception as e:
                ips.append({'error': str(e)})
        
        return ips
    
    port = int(os.environ.get('PORT', 5001))
    
    return jsonify({
        'server_binding': {
            'host': '0.0.0.0',
            'port': port,
            'accessible_on': 'All network interfaces'
        },
        'detected_ips': get_all_ips(),
        'recommended_urls': [
            f'http://{ip["ip"]}:{port}' 
            for ip in get_all_ips() 
            if ip.get('ip') and not ip['ip'].startswith('127.')
        ],
        'current_request': {
            'host': request.host,
            'remote_addr': request.remote_addr,
            'url': request.url,
            'scheme': request.scheme
        },
        'environment': {
            'HOST_IP': os.environ.get('HOST_IP'),
            'PORT': os.environ.get('PORT', '5001')
        }
    })

@app.route('/api/qrcode', methods=['GET'])
def generate_qrcode():
    """Generate a QR code for the server URL."""

    port = int(os.environ.get('PORT', 5001))

    # Try to get IP: first check HOST_IP, then auto-detect
    try:
        # If HOST_IP is explicitly set, use it
        if os.environ.get('HOST_IP'):
            local_ip = get_local_ip()  # This will use the explicitly set HOST_IP
        else:
            # Auto-detect IP address for convenience
            local_ip = get_local_ip_dynamic()
            print(f"🌐 Auto-detected IP for QR code: {local_ip}")
    except RuntimeError as e:
        # Return error image instead of crashing
        from PIL import Image, ImageDraw, ImageFont
        img = Image.new('RGB', (300, 150), color='white')
        draw = ImageDraw.Draw(img)
        # Try to use a default font, fall back to basic if not available
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Arial.ttf", 16)
        except:
            font = ImageFont.load_default()

        error_text = "Could not detect network IP!\nCheck Wi-Fi connection."
        draw.text((10, 10), error_text, fill='red', font=font)

        img_io = io.BytesIO()
        img.save(img_io, 'PNG')
        img_io.seek(0)
        return Response(img_io.getvalue(), mimetype='image/png')

    server_url = f'http://{local_ip}:{port}'

    # Generate QR code
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(server_url)
    qr.make(fit=True)

    # Create image
    img = qr.make_image(fill_color="black", back_color="white")

    # Convert to bytes
    img_io = io.BytesIO()
    img.save(img_io, 'PNG')
    img_io.seek(0)

    return Response(img_io.getvalue(), mimetype='image/png')

# WebSocket event handlers
@socketio.on('connect')
def handle_connect():
    """Handle client connection."""
    session_id = request.sid
    print(f"🔌 Client connected: {session_id}")
    try:
        print(f"   Namespace: {request.namespace}")
    except AttributeError:
        pass
    # Note: Flask-SocketIO should automatically handle Socket.IO protocol ping/pong (packets "2" and "3")
    emit('connected', {'status': 'connected', 'message': 'Successfully connected to CacheRaiders WebSocket'})
    
    # Track connection (device_uuid will be set when client identifies itself)
    # For now, just track the session
    connected_clients[session_id] = None  # Will be updated when client sends device_uuid

@socketio.on('disconnect')
def handle_disconnect():
    """Handle client disconnection."""
    session_id = request.sid
    print(f"🔌 Client disconnected: {session_id}")
    
    # Remove from tracking
    device_uuid = connected_clients.pop(session_id, None)
    if device_uuid and device_uuid in client_sessions:
        client_sessions[device_uuid].discard(session_id)
        if not client_sessions[device_uuid]:
            del client_sessions[device_uuid]

@socketio.on('ping')
def handle_ping():
    """Handle ping for keepalive (named event, not Socket.IO protocol ping)."""
    # Note: Socket.IO protocol ping/pong (packets "2" and "3") is handled automatically by Flask-SocketIO
    # This handler is for custom named 'ping' events, not protocol-level ping
    emit('pong', {'timestamp': datetime.utcnow().isoformat()})

@socketio.on('register_device')
def handle_register_device(data):
    """Register a device UUID for this WebSocket session."""
    session_id = request.sid
    device_uuid = data.get('device_uuid')
    
    print(f"📱 [register_device] Received registration request from session {session_id[:8]}...")
    print(f"   Device UUID: {device_uuid[:8] if device_uuid else 'MISSING'}...")
    
    if not device_uuid:
        print("   ❌ No device_uuid provided in registration data")
        emit('device_registered', {'error': 'device_uuid required', 'status': 'error'})
        return
    
    # Update tracking
    old_uuid = connected_clients.get(session_id)
    connected_clients[session_id] = device_uuid
    
    # Update reverse mapping
    if old_uuid and old_uuid in client_sessions:
        client_sessions[old_uuid].discard(session_id)
        if not client_sessions[old_uuid]:
            del client_sessions[old_uuid]
        print(f"   🔄 Removed old UUID mapping: {old_uuid[:8]}...")
    
    if device_uuid not in client_sessions:
        client_sessions[device_uuid] = set()
    client_sessions[device_uuid].add(session_id)
    
    print(f"✅ Device registered: {device_uuid[:8]}... (session: {session_id[:8]}...)")
    print(f"   Total registered clients: {len(client_sessions)}")
    emit('device_registered', {'device_uuid': device_uuid, 'status': 'registered'})

@socketio.on('diagnostic_ping')
def handle_diagnostic_ping(data):
    """Handle diagnostic ping request from admin panel."""
    session_id = request.sid
    ping_id = data.get('ping_id')
    timestamp = data.get('timestamp')
    
    # Respond immediately with pong
    emit('diagnostic_pong', {
        'ping_id': ping_id,
        'timestamp': timestamp,
        'server_timestamp': datetime.utcnow().isoformat(),
        'session_id': session_id
    })

@socketio.on('admin_ping_client')
def handle_admin_ping_client(data):
    """Admin panel requests to ping a specific client device."""
    target_device_uuid = data.get('device_uuid')
    ping_id = data.get('ping_id', str(datetime.utcnow().timestamp()))
    admin_session_id = request.sid
    
    if not target_device_uuid:
        emit('admin_ping_error', {'error': 'device_uuid required', 'ping_id': ping_id})
        return
    
    # Find sessions for this device
    target_sessions = client_sessions.get(target_device_uuid, set())
    
    if not target_sessions:
        emit('admin_ping_error', {
            'error': f'Device {target_device_uuid[:8]}... not connected',
            'ping_id': ping_id,
            'device_uuid': target_device_uuid
        })
        return
    
    # Send ping to all sessions for this device
    ping_timestamp = datetime.utcnow().isoformat()
    for target_session in target_sessions:
        socketio.emit('admin_diagnostic_ping', {
            'ping_id': ping_id,
            'timestamp': ping_timestamp,
            'admin_session_id': admin_session_id
        }, room=target_session)
    
    print(f"📡 Admin ping sent to device {target_device_uuid[:8]}... (ping_id: {ping_id})")

@socketio.on('client_diagnostic_pong')
def handle_client_diagnostic_pong(data):
    """Client responds to admin diagnostic ping."""
    ping_id = data.get('ping_id')
    client_timestamp = data.get('client_timestamp')
    admin_session_id = data.get('admin_session_id')
    device_uuid = connected_clients.get(request.sid)
    
    # Forward pong to admin session
    if admin_session_id:
        socketio.emit('admin_ping_response', {
            'ping_id': ping_id,
            'device_uuid': device_uuid,
            'client_timestamp': client_timestamp,
            'server_timestamp': datetime.utcnow().isoformat(),
            'latency_ms': None  # Will be calculated by admin panel
        }, room=admin_session_id)
        
        print(f"📡 Client pong received from {device_uuid[:8] if device_uuid else 'unknown'}... (ping_id: {ping_id})")

@socketio.on('get_connected_clients')
def handle_get_connected_clients():
    """Get list of all connected clients for admin panel."""
    clients_info = []
    for device_uuid, sessions in client_sessions.items():
        clients_info.append({
            'device_uuid': device_uuid,
            'session_count': len(sessions),
            'session_ids': list(sessions)
        })
    
    print(f"📡 [get_connected_clients] Returning {len(clients_info)} connected client(s)")
    if len(clients_info) == 0:
        print("   ⚠️ No clients registered - check if iOS app is connected and registered device UUID")
        print(f"   Total WebSocket sessions: {len(connected_clients)}")
        print(f"   Sessions without device UUID: {sum(1 for uuid in connected_clients.values() if uuid is None)}")
    
    emit('connected_clients_list', {'clients': clients_info})

# ============================================================================
# LLM Integration Endpoints
# ============================================================================

@app.route('/api/llm/test', methods=['GET', 'POST'])
def test_llm():
    """Test if LLM service is working. Accepts optional custom prompt via POST."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    # Get custom prompt if provided via POST
    custom_prompt = None
    if request.method == 'POST' and request.json:
        custom_prompt = request.json.get('prompt')
    
    # Log current provider/model before test
    provider_info = llm_service.get_provider_info()
    print(f"🧪 [API] test_llm called - Current provider: {provider_info.get('provider')}, model: {provider_info.get('model')}, custom_prompt: {bool(custom_prompt)}")
    
    result = llm_service.test_connection(custom_prompt=custom_prompt)
    
    # Log result
    print(f"🧪 [API] test_llm result - Provider: {result.get('provider')}, model: {result.get('model')}, status: {result.get('status')}")
    
    return jsonify(result), 200 if result['status'] == 'success' else 500

@app.route('/api/llm/test-connection', methods=['GET'])
def test_llm_connection():
    """Test LLM connection (alias for /api/llm/test for consistency with error messages)."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    # For Ollama, also run diagnostics
    provider_info = llm_service.get_provider_info()
    if provider_info.get('provider') in ['ollama', 'local']:
        # Run the test first
        test_result = llm_service.test_connection()
        
        # Also get diagnostic info
        diagnose_result = {
            'ollama_base_url': llm_service.ollama_base_url,
            'docker_container': bool(os.getenv('DOCKER_CONTAINER')),
            'connection_test': None,
            'models_available': [],
            'error': None
        }
        
        # Try to get models if connection works
        try:
            import requests
            ollama_url = llm_service.ollama_base_url
            response = requests.get(f"{ollama_url}/api/tags", timeout=10)
            if response.status_code == 200:
                data = response.json()
                models = [m.get('name', m.get('model', '')) for m in data.get('models', [])]
                diagnose_result['connection_test'] = 'success'
                diagnose_result['models_available'] = models
        except:
            diagnose_result['connection_test'] = 'failed'
        
        # Merge results
        combined = {
            'status': test_result.get('status'),
            'provider': test_result.get('provider'),
            'model': test_result.get('model'),
            'response': test_result.get('response'),
            'error': test_result.get('error'),
            'ollama_base_url': diagnose_result.get('ollama_base_url'),
            'docker_container': diagnose_result.get('docker_container'),
            'connection_test': diagnose_result.get('connection_test'),
            'models_available': diagnose_result.get('models_available')
        }
        return jsonify(combined), 200 if test_result.get('status') == 'success' else 500
    else:
        # For non-Ollama providers, just run the test
        return test_llm()

@app.route('/api/llm/warmup', methods=['POST'])
def warmup_llm():
    """Warm up the LLM model (pre-loads into memory for faster responses)."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    result = llm_service.warmup_model()
    status_code = 200 if result.get('status') == 'success' else 500
    return jsonify(result), status_code

@app.route('/api/llm/ollama/diagnose', methods=['GET'])
def diagnose_ollama():
    """Diagnose Ollama connectivity and model availability."""
    result = {
        'ollama_base_url': llm_service.ollama_base_url,
        'docker_container': bool(os.getenv('DOCKER_CONTAINER')),
        'connection_test': None,
        'models_available': [],
        'error': None
    }
    
    try:
        import requests
        ollama_url = llm_service.ollama_base_url
        
        # Test basic connectivity
        try:
            response = requests.get(f"{ollama_url}/api/tags", timeout=10)
            if response.status_code == 200:
                data = response.json()
                models = [m.get('name', m.get('model', '')) for m in data.get('models', [])]
                result['connection_test'] = 'success'
                result['models_available'] = models
                result['message'] = f"✅ Connected to Ollama at {ollama_url}. Found {len(models)} model(s)."
            else:
                result['connection_test'] = 'failed'
                result['error'] = f"Ollama returned status {response.status_code}"
                result['message'] = f"⚠️ Ollama at {ollama_url} returned HTTP {response.status_code}"
        except requests.exceptions.ConnectionError as e:
            result['connection_test'] = 'failed'
            result['error'] = f"Connection error: {str(e)}"
            is_docker = os.getenv('DOCKER_CONTAINER', '').lower() in ('true', '1', 'yes')
            if is_docker:
                result['message'] = f"❌ Cannot connect to Ollama at {ollama_url}. Check if container is running: docker ps | grep ollama. If running, check container logs: docker logs cache-raiders-ollama"
            else:
                result['message'] = f"❌ Cannot connect to Ollama at {ollama_url}. Make sure Ollama is running locally: ollama serve (or check if Docker container is running: docker ps | grep ollama)"
        except requests.exceptions.Timeout:
            result['connection_test'] = 'failed'
            result['error'] = "Request timed out"
            result['message'] = f"⏱️ Ollama at {ollama_url} did not respond within 10 seconds"
        except Exception as e:
            result['connection_test'] = 'failed'
            result['error'] = f"Unexpected error: {str(e)}"
            result['message'] = f"❌ Error testing Ollama: {str(e)}"
    except Exception as e:
        result['connection_test'] = 'error'
        result['error'] = f"Diagnostic error: {str(e)}"
        result['message'] = f"❌ Failed to run diagnostic: {str(e)}"
    
    return jsonify(result), 200

@app.route('/api/llm/provider', methods=['GET'])
def get_llm_provider():
    """Get current LLM provider configuration."""
    print(f"📥 [API] GET /api/llm/provider called")
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    info = llm_service.get_provider_info()
    print(f"📊 [API] Provider info: {info.get('provider')}, model: {info.get('model')}")
    
    # Don't modify ollama_base_url - it was already set correctly in __init__
    # Just log what we're using
    if info.get('provider') == 'ollama':
        print(f"🔧 [API] Using Ollama at: {llm_service.ollama_base_url}")
    
    # If Ollama, also fetch available models
    if info.get('provider') == 'ollama':
        print(f"🔍 [API] Starting to fetch Ollama models...")
        try:
            import requests
            ollama_url = llm_service.ollama_base_url
            print(f"🔍 Fetching Ollama models from: {ollama_url}/api/tags")
            # Quick timeout - if Ollama is slow, we'll show an error
            response = requests.get(f"{ollama_url}/api/tags", timeout=5)
            if response.status_code == 200:
                data = response.json()
                models = [m.get('name', m.get('model', '')) for m in data.get('models', [])]
                info['available_models'] = models
                print(f"✅ Found {len(models)} Ollama models: {', '.join(models) if models else 'none'}")
            else:
                info['available_models'] = []
                error_msg = f"Ollama API returned status {response.status_code}"
                info['ollama_error'] = error_msg
                print(f"⚠️ {error_msg}")
        except requests.exceptions.ConnectionError as e:
            info['available_models'] = []
            ollama_url = llm_service.ollama_base_url
            error_msg = f"Cannot connect to Ollama at {ollama_url}"
            info['ollama_error'] = error_msg
            info['ollama_base_url'] = ollama_url
            print(f"⚠️ {error_msg}: {e}")
        except requests.exceptions.Timeout:
            info['available_models'] = []
            ollama_url = llm_service.ollama_base_url
            error_msg = f"Ollama request timed out after 5s at {ollama_url}"
            info['ollama_error'] = error_msg
            info['ollama_base_url'] = ollama_url
            print(f"⚠️ {error_msg}")
        except Exception as e:
            info['available_models'] = []
            ollama_url = llm_service.ollama_base_url
            error_msg = f"Error fetching Ollama models from {ollama_url}: {str(e)}"
            info['ollama_error'] = error_msg
            info['ollama_base_url'] = ollama_url
            print(f"⚠️ {error_msg}")
            import traceback
            traceback.print_exc()
    
    return jsonify(info), 200

@app.route('/api/llm/provider', methods=['POST'])
def set_llm_provider():
    """Switch LLM provider (openai, ollama, or local) and persist to database."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    data = request.json
    provider = data.get('provider')
    model = data.get('model')  # Optional: can specify model for the provider
    
    if not provider:
        return jsonify({'error': 'provider is required'}), 400
    
    # ollama_base_url was already set correctly in __init__ - don't modify it
    
    # Log the request for debugging
    print(f"🔄 [API] Setting LLM provider: {provider}, model: {model}")
    
    result = llm_service.set_provider(provider, model)
    
    if 'error' in result:
        return jsonify(result), 400
    
    # Persist to database
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Save provider
        cursor.execute('''
            INSERT OR REPLACE INTO settings (key, value, updated_at)
            VALUES (?, ?, ?)
        ''', ('llm_provider', result.get('provider'), datetime.utcnow().isoformat()))
        
        # Save model
        if result.get('model'):
            cursor.execute('''
                INSERT OR REPLACE INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
            ''', ('llm_model', result.get('model'), datetime.utcnow().isoformat()))
        
        conn.commit()
        conn.close()
        print(f"💾 Persisted LLM settings to database: provider={result.get('provider')}, model={result.get('model')}")
    except Exception as e:
        print(f"⚠️ Error persisting LLM settings to database: {e}")
        import traceback
        traceback.print_exc()
        # Continue anyway - in-memory value is set
    
    # Fetch available models if Ollama (same as GET endpoint)
    if result.get('provider') == 'ollama':
        try:
            import requests
            ollama_url = llm_service.ollama_base_url
            print(f"🔍 [API] Fetching Ollama models from {ollama_url}/api/tags after provider change...")
            response = requests.get(f"{ollama_url}/api/tags", timeout=10)
            if response.status_code == 200:
                data = response.json()
                models = [m.get('name', m.get('model', '')) for m in data.get('models', [])]
                result['available_models'] = models
                result['ollama_base_url'] = ollama_url
                print(f"✅ [API] Found {len(models)} Ollama models: {', '.join(models) if models else 'none'}")
                
                # Verify the selected model is actually available
                selected_model = result.get('model')
                if selected_model and models and selected_model not in models:
                    # Check if model name matches (with or without tag)
                    model_found = any(m.startswith(selected_model.split(':')[0]) for m in models)
                    if not model_found:
                        print(f"⚠️ [API] Selected model '{selected_model}' not in available models. Available: {models}")
                        # Use first available model or default
                        if models:
                            result['model'] = models[0]
                            result['model_warning'] = f"Selected model not available, switched to {models[0]}"
                            print(f"🔄 [API] Switched to available model: {models[0]}")
            else:
                result['available_models'] = []
                result['ollama_error'] = f"Ollama API returned status {response.status_code}"
                result['ollama_base_url'] = ollama_url
                print(f"⚠️ [API] Ollama API returned status {response.status_code}")
        except requests.exceptions.ConnectionError as e:
            result['available_models'] = []
            ollama_url = llm_service.ollama_base_url
            is_docker = os.getenv('DOCKER_CONTAINER', '').lower() in ('true', '1', 'yes')
            print(f"🔍 [API] Connection error in POST - is_docker={is_docker}, DOCKER_CONTAINER={os.getenv('DOCKER_CONTAINER')}, ollama_url={ollama_url}")
            if is_docker:
                error_msg = f"Cannot connect to Ollama at {ollama_url}. Make sure the Ollama container is running: docker ps | grep ollama. If running, check container logs: docker logs cache-raiders-ollama"
            else:
                error_msg = f"Cannot connect to Ollama at {ollama_url}. Make sure Ollama is running locally: ollama serve (or check if Docker container is running: docker ps | grep ollama)"
            result['ollama_error'] = error_msg
            result['ollama_base_url'] = ollama_url
            print(f"⚠️ {error_msg}: {e}")
        except requests.exceptions.Timeout:
            result['available_models'] = []
            ollama_url = llm_service.ollama_base_url
            error_msg = f"Ollama request timed out at {ollama_url}. Check if Ollama is healthy."
            result['ollama_error'] = error_msg
            result['ollama_base_url'] = ollama_url
            print(f"⚠️ {error_msg}")
        except Exception as e:
            result['available_models'] = []
            ollama_url = llm_service.ollama_base_url
            error_msg = f"Error fetching Ollama models from {ollama_url}: {str(e)}"
            result['ollama_error'] = error_msg
            result['ollama_base_url'] = ollama_url
            print(f"⚠️ {error_msg}")
            import traceback
            traceback.print_exc()
    
    # Log the result for debugging
    print(f"✅ [API] LLM provider set to: {result.get('provider')}, model: {result.get('model')}")
    
    return jsonify(result), 200

@app.route('/api/npcs/<npc_id>/interact', methods=['POST'])
def interact_with_npc(npc_id: str):
    """Interact with an NPC (including skeletons) via LLM conversation."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    data = request.json
    device_uuid = data.get('device_uuid')
    message = data.get('message')
    
    if not device_uuid or not message:
        return jsonify({'error': 'device_uuid and message required'}), 400
    
    # For now, we'll use a simple skeleton NPC
    # In full implementation, this would fetch NPC data from database
    npc_name = data.get('npc_name', 'Captain Bones')
    npc_type = data.get('npc_type', 'skeleton')
    is_skeleton = data.get('is_skeleton', True)  # Default to skeleton for testing
    
    try:
        # Get user location if provided (for OSM-based clues)
        user_location = data.get('user_location')
        include_placement = data.get('include_placement', False)
        
        result = llm_service.generate_npc_response(
            npc_name=npc_name,
            npc_type=npc_type,
            user_message=message,
            is_skeleton=is_skeleton,
            include_placement=include_placement,
            user_location=user_location
        )
        
        # Get current LLM provider info to include in response
        provider_info = llm_service.get_provider_info()
        model_name = provider_info.get('model', 'unknown')
        provider = provider_info.get('provider', 'unknown')
        
        # Handle both old string return and new dict return for backward compatibility
        if isinstance(result, dict):
            response_text = result.get('response', '')
            placement = result.get('placement')
            
            response_data = {
                'npc_id': npc_id,
                'response': response_text,
                'npc_name': npc_name,
                'model': model_name,
                'provider': provider
            }
            
            if placement:
                response_data['placement'] = placement
            
            return jsonify(response_data), 200
        else:
            # Backward compatibility: if it returns a string
            return jsonify({
                'npc_id': npc_id,
                'response': result,
                'npc_name': npc_name,
                'model': model_name,
                'provider': provider
            }), 200
    except Exception as e:
        return jsonify({'error': f'LLM error: {str(e)}'}), 500

@app.route('/api/llm/generate-clue', methods=['POST'])
def generate_clue():
    """Generate a pirate riddle clue based on REAL map features from OpenStreetMap."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    data = request.json
    target_location = data.get('target_location', {})
    map_features = data.get('map_features', [])  # Optional: can provide features or let it fetch
    fetch_real = data.get('fetch_real_features', True)  # Default to fetching real features
    
    if not target_location.get('latitude') or not target_location.get('longitude'):
        return jsonify({'error': 'target_location must include latitude and longitude'}), 400
    
    try:
        clue = llm_service.generate_clue(target_location, map_features, fetch_real_features=fetch_real)
        return jsonify({
            'clue': clue,
            'target_location': target_location,
            'used_real_map_data': fetch_real and not map_features
        }), 200
    except Exception as e:
        return jsonify({'error': f'LLM error: {str(e)}'}), 500

@app.route('/api/settings/location-update-interval', methods=['GET'])
def get_location_update_interval():
    """Get the current location update interval in milliseconds."""
    return jsonify({
        'interval_ms': location_update_interval_ms,
        'interval_seconds': location_update_interval_ms / 1000.0
    })

@app.route('/api/settings/location-update-interval', methods=['POST', 'PUT'])
def set_location_update_interval():
    """Set the location update interval in milliseconds and persist to database."""
    global location_update_interval_ms
    
    try:
        data = request.get_json()
        if not data or 'interval_ms' not in data:
            return jsonify({'error': 'interval_ms is required'}), 400
        
        interval_ms = int(data['interval_ms'])
        
        # Validate interval (must be one of the allowed values: 500, 1000, 3000, 5000, 10000, 30000, 60000)
        allowed_intervals = [500, 1000, 3000, 5000, 10000, 30000, 60000]
        if interval_ms not in allowed_intervals:
            return jsonify({
                'error': f'Invalid interval. Must be one of: {[ms/1000 for ms in allowed_intervals]} seconds'
            }), 400
        
        location_update_interval_ms = interval_ms
        
        # Persist to database - verify it was saved
        db_save_success = False
        db_error = None
        try:
            # Ensure database is initialized
            if not os.path.exists(DB_PATH):
                print(f"⚠️ Database file does not exist: {DB_PATH}, initializing...")
                init_db()
            
            conn = get_db_connection()
            cursor = conn.cursor()
            
            # Ensure settings table exists
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            ''')
            
            # Save the value
            cursor.execute('''
                INSERT OR REPLACE INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
            ''', ('location_update_interval_ms', str(location_update_interval_ms), datetime.utcnow().isoformat()))
            conn.commit()
            
            # Verify the save worked by reading it back
            cursor.execute('SELECT value FROM settings WHERE key = ?', ('location_update_interval_ms',))
            row = cursor.fetchone()
            if row and int(row['value']) == location_update_interval_ms:
                db_save_success = True
                print(f"💾 Persisted location update interval to database: {location_update_interval_ms}ms (verified)")
            else:
                db_error = "Save verification failed - value mismatch"
                print(f"⚠️ Warning: Location update interval may not have been saved correctly")
            conn.close()
        except sqlite3.OperationalError as e:
            db_error = f"Database operational error: {str(e)}"
            print(f"⚠️ Error persisting location update interval to database: {e}")
            import traceback
            traceback.print_exc()
        except Exception as e:
            db_error = f"Unexpected error: {str(e)}"
            print(f"⚠️ Error persisting location update interval to database: {e}")
            import traceback
            traceback.print_exc()
        
        # If save failed, return error but still set in-memory value
        if not db_save_success:
            print(f"⚠️ Database save failed, but in-memory value is set to {location_update_interval_ms}ms")
            # Don't return error - allow in-memory value to be used, but log the issue
        
        # Broadcast the new interval to all connected clients via WebSocket
        # Note: emit without 'room' or 'to' broadcasts to all (broadcast=True is deprecated)
        try:
            socketio.emit('location_update_interval_changed', {
                'interval_ms': location_update_interval_ms,
                'interval_seconds': location_update_interval_ms / 1000.0
            })
        except Exception as e:
            print(f"⚠️ Error broadcasting location update interval via WebSocket: {e}")
            # Continue anyway - the value is set
        
        print(f"📍 Location update interval changed to {location_update_interval_ms}ms ({location_update_interval_ms/1000.0}s)")
        
        return jsonify({
            'interval_ms': location_update_interval_ms,
            'interval_seconds': location_update_interval_ms / 1000.0,
            'message': f'Location update interval set to {location_update_interval_ms/1000.0} seconds'
        })
    except ValueError as e:
        print(f"⚠️ Invalid value for location update interval: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Invalid value: {str(e)}'}), 400
    except Exception as e:
        print(f"⚠️ Error setting location update interval: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Internal server error: {str(e)}'}), 500

def load_location_update_interval_from_db():
    """Load location update interval from database on startup."""
    global location_update_interval_ms
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT value FROM settings WHERE key = ?', ('location_update_interval_ms',))
        row = cursor.fetchone()
        if row:
            location_update_interval_ms = int(row['value'])
            print(f"📍 Loaded location update interval from database: {location_update_interval_ms}ms")
        else:
            # Initialize with default if not found
            cursor.execute('''
                INSERT INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
            ''', ('location_update_interval_ms', '1000', datetime.utcnow().isoformat()))
            conn.commit()
            location_update_interval_ms = 1000
            print(f"📍 Initialized location update interval to default: {location_update_interval_ms}ms")
        conn.close()
    except Exception as e:
        print(f"⚠️ Error loading location update interval from database: {e}, using default: 1000ms")
        location_update_interval_ms = 1000

def load_game_mode_from_db():
    """Load game mode from database on startup."""
    global game_mode
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT value FROM settings WHERE key = ?', ('game_mode',))
        row = cursor.fetchone()
        if row:
            game_mode = row['value']
            print(f"🎮 Loaded game mode from database: {game_mode}")
        else:
            # Initialize with default if not found
            cursor.execute('''
                INSERT INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
            ''', ('game_mode', 'open', datetime.utcnow().isoformat()))
            conn.commit()
            game_mode = 'open'
            print(f"🎮 Initialized game mode to default: {game_mode}")
        conn.close()
    except Exception as e:
        print(f"⚠️ Error loading game mode from database: {e}, using default: open")
        game_mode = 'open'

def load_llm_settings_from_db():
    """Load LLM provider and model from database on startup."""
    if not LLM_AVAILABLE:
        return
    
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Load provider
        cursor.execute('SELECT value FROM settings WHERE key = ?', ('llm_provider',))
        row = cursor.fetchone()
        provider = row['value'] if row else None
        
        # Load model
        cursor.execute('SELECT value FROM settings WHERE key = ?', ('llm_model',))
        row = cursor.fetchone()
        model = row['value'] if row else None
        
        conn.close()
        
        # Apply settings if found
        if provider:
            print(f"🤖 Loading LLM settings from database: provider={provider}, model={model or 'default'}")
            result = llm_service.set_provider(provider, model)
            if 'error' not in result:
                print(f"✅ Loaded LLM settings: provider={result.get('provider')}, model={result.get('model')}")
            else:
                print(f"⚠️ Error loading LLM settings: {result.get('error')}")
        else:
            print(f"ℹ️ No LLM settings found in database, using defaults from environment")
    except Exception as e:
        print(f"⚠️ Error loading LLM settings from database: {e}, using defaults")
        import traceback
        traceback.print_exc()

@app.route('/api/settings/game-mode', methods=['GET'])
def get_game_mode():
    """Get the current game mode."""
    print(f"🎮 [DEBUG] get_game_mode() called from {request.remote_addr}", flush=True)
    print(f"   Current game_mode value: '{game_mode}'", flush=True)
    response_data = {
        'game_mode': game_mode
    }
    print(f"   Returning: {response_data}", flush=True)
    return jsonify(response_data)

@app.route('/api/settings/game-mode', methods=['POST', 'PUT'])
def set_game_mode():
    """Set the game mode and persist to database."""
    import sys
    # DEBUG: Log every request to this endpoint
    print(f"🔔 [DEBUG] set_game_mode endpoint called!", flush=True)
    print(f"   Method: {request.method}", flush=True)
    print(f"   Remote addr: {request.remote_addr}", flush=True)
    sys.stdout.flush()
    
    try:
        global game_mode
        
        data = request.get_json()
        print(f"   Request data: {data}", flush=True)
        sys.stdout.flush()
        if not data or 'game_mode' not in data:
            return jsonify({'error': 'game_mode is required'}), 400
        
        new_game_mode = str(data['game_mode'])
        
        # Validate game mode (must be one of: "open", "dead_mens_secrets")
        allowed_modes = ["open", "dead_mens_secrets"]
        if new_game_mode not in allowed_modes:
            return jsonify({
                'error': f'Invalid game mode. Must be one of: {allowed_modes}'
            }), 400
        
        # Update in-memory variable
        game_mode = new_game_mode
        
        # Persist to database
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute('''
                INSERT OR REPLACE INTO settings (key, value, updated_at)
                VALUES (?, ?, ?)
            ''', ('game_mode', game_mode, datetime.utcnow().isoformat()))
            conn.commit()
            conn.close()
            print(f"💾 Persisted game mode to database: {game_mode}")
        except Exception as e:
            print(f"⚠️ Error persisting game mode to database: {e}")
            import traceback
            traceback.print_exc()
            # Continue anyway - in-memory value is set
        
        # Broadcast the new game mode to all connected clients via WebSocket
        try:
            # Flask-SocketIO: emit without 'room' or 'to' broadcasts to all connected clients
            # Note: 'broadcast=True' was removed as it's deprecated in newer python-socketio versions
            event_data = {
                'game_mode': game_mode
            }
            print(f"📡 [Game Mode] Broadcasting game_mode_changed event to all clients", flush=True)
            print(f"   Event data: {event_data}", flush=True)
            print(f"   Number of connected clients: {len(connected_clients)}", flush=True)
            print(f"   WebSocket sessions (connected_clients dict): {list(connected_clients.keys())}", flush=True)
            
            # Emit to all connected clients (no room = broadcast to all)
            # DEBUG: Log the exact emit call
            print(f"   🔔 Calling socketio.emit('game_mode_changed', {event_data}, namespace='/')", flush=True)
            socketio.emit('game_mode_changed', event_data, namespace='/')
            print(f"✅ [Game Mode] Broadcasted game mode change to all connected clients: {game_mode}", flush=True)
            
            # Also try emitting without namespace to see if that helps
            print(f"   🔔 Also trying emit without namespace...", flush=True)
            socketio.emit('game_mode_changed', event_data)
            print(f"   ✅ Second emit completed", flush=True)
        except Exception as e:
            print(f"❌ [Game Mode] Error broadcasting game mode change via WebSocket: {e}")
            import traceback
            traceback.print_exc()
            # Continue anyway - game mode is still set
        
        print(f"🎮 Game mode changed to: {game_mode}")
        
        return jsonify({
            'game_mode': game_mode,
            'message': f'Game mode set to {game_mode}'
        })
    except Exception as e:
        print(f"❌ Error in set_game_mode endpoint: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({
            'error': f'Internal server error: {str(e)}'
        }), 500

@app.route('/api/npcs/<npc_id>/map-piece', methods=['GET', 'POST'])
def get_npc_map_piece(npc_id: str):
    """Get a treasure map piece from an NPC (skeleton has first half, corgi has second half).
    
    IMPORTANT: Treasure location (X marks the spot) is generated ONCE and saved to database.
    Subsequent requests return the same treasure location for the user.
    """
    import time
    import random
    request_start_time = time.time()
    request_id = f"{npc_id}_{int(time.time() * 1000)}"
    
    map_logger.info(f"[{request_id}] ========== MAP REQUEST STARTED ==========")
    map_logger.info(f"[{request_id}] NPC ID: {npc_id}")
    map_logger.info(f"[{request_id}] Method: {request.method}")
    map_logger.info(f"[{request_id}] Headers: {dict(request.headers)}")
    
    if not LLM_AVAILABLE:
        map_logger.error(f"[{request_id}] LLM service not available")
        return jsonify({'error': 'LLM service not available'}), 503
    
    # Determine which NPC and which piece
    npc_type = "skeleton" if "skeleton" in npc_id.lower() else "corgi"
    piece_number = 1 if npc_type == "skeleton" else 2
    map_logger.info(f"[{request_id}] NPC Type: {npc_type}, Piece Number: {piece_number}")
    
    # Get device_uuid from request (required for treasure hunt persistence)
    device_uuid = None
    if request.json and 'device_uuid' in request.json:
        device_uuid = request.json.get('device_uuid')
    elif request.args.get('device_uuid'):
        device_uuid = request.args.get('device_uuid')
    
    map_logger.info(f"[{request_id}] Device UUID: {device_uuid}")
    
    # Get target location from request (JSON body or query params)
    target_location = {}
    # Try to get from JSON body first (works for both GET and POST)
    # Note: Flask may not parse JSON body for GET requests, so we need to handle it manually
    if request.method == 'GET' and request.content_length and request.content_length > 0:
        # For GET requests with body, manually parse JSON
        try:
            import json
            body_data = json.loads(request.get_data(as_text=True))
            if 'target_location' in body_data:
                target_location = body_data.get('target_location', {})
                map_logger.info(f"[{request_id}] Target location from JSON body (GET): {target_location}")
        except (json.JSONDecodeError, ValueError) as e:
            map_logger.warning(f"[{request_id}] Failed to parse JSON body for GET request: {e}")
    elif request.json and 'target_location' in request.json:
        target_location = request.json.get('target_location', {})
        map_logger.info(f"[{request_id}] Target location from JSON body: {target_location}")
    # Fallback to query params for GET requests without body
    if request.method == 'GET' and not target_location:
        lat = request.args.get('latitude')
        lon = request.args.get('longitude')
        if lat and lon:
            target_location = {'latitude': float(lat), 'longitude': float(lon)}
            map_logger.info(f"[{request_id}] Target location from query params: {target_location}")
    
    # If no target provided, use a default location (for testing)
    if not target_location.get('latitude') or not target_location.get('longitude'):
        # Default to San Francisco for testing
        target_location = {
            'latitude': 37.7749,
            'longitude': -122.4194
        }
        map_logger.warning(f"[{request_id}] No target location provided, using default: {target_location}")
    
    # Store the user's original location (before we potentially modify target_location)
    user_location = {
        'latitude': target_location.get('latitude'),
        'longitude': target_location.get('longitude')
    }
    
    # Check if user has an existing active treasure hunt
    existing_hunt = None
    if device_uuid:
        try:
            conn = get_db_connection()
            cursor = conn.cursor()
            cursor.execute('''
                SELECT id, treasure_latitude, treasure_longitude, origin_latitude, origin_longitude,
                       map_piece_1_json, map_piece_2_json, created_at
                FROM treasure_hunts 
                WHERE device_uuid = ? AND status = 'active'
                ORDER BY created_at DESC
                LIMIT 1
            ''', (device_uuid,))
            row = cursor.fetchone()
            if row:
                existing_hunt = {
                    'id': row[0],
                    'treasure_latitude': row[1],
                    'treasure_longitude': row[2],
                    'origin_latitude': row[3],
                    'origin_longitude': row[4],
                    'map_piece_1_json': row[5],
                    'map_piece_2_json': row[6],
                    'created_at': row[7]
                }
                map_logger.info(f"[{request_id}] Found existing treasure hunt: id={existing_hunt['id']}, treasure=({existing_hunt['treasure_latitude']}, {existing_hunt['treasure_longitude']})")
            conn.close()
        except Exception as e:
            map_logger.error(f"[{request_id}] Error checking existing treasure hunt: {e}")
    
    # If existing hunt found, return the saved map piece
    if existing_hunt:
        map_piece_key = f'map_piece_{piece_number}_json'
        saved_piece_json = existing_hunt.get(map_piece_key)
        
        if saved_piece_json:
            try:
                import json
                saved_piece = json.loads(saved_piece_json)
                map_logger.info(f"[{request_id}] Returning saved map piece {piece_number} from database")
                
                total_duration = time.time() - request_start_time
                map_logger.info(f"[{request_id}] ========== MAP REQUEST SUCCESS (CACHED) ==========")
                map_logger.info(f"[{request_id}] Total duration: {total_duration:.2f}s")
                
                return jsonify({
                    'npc_id': npc_id,
                    'npc_type': npc_type,
                    'map_piece': saved_piece,
                    'message': f"Here's piece {piece_number} of the treasure map!",
                    'from_cache': True,
                    'treasure_hunt_id': existing_hunt['id']
                }), 200
            except json.JSONDecodeError as e:
                map_logger.warning(f"[{request_id}] Failed to parse saved map piece: {e}")
                # Continue to generate new piece
        
        # If we have an existing hunt but no saved piece for this NPC, use the saved treasure location
        target_location = {
            'latitude': existing_hunt['treasure_latitude'],
            'longitude': existing_hunt['treasure_longitude']
        }
        map_logger.info(f"[{request_id}] Using existing treasure location: {target_location}")
    else:
        # NEW treasure hunt - generate treasure location within 10 meters of user
        # This makes the treasure easy to find and test
        import random
        import math
        
        user_lat = user_location.get('latitude')
        user_lon = user_location.get('longitude')
        
        if user_lat and user_lon:
            # Generate random point within 10 meters
            max_distance_m = 10.0
            
            # Convert meters to approximate degrees
            # 1 degree latitude ≈ 111,000 meters
            # 1 degree longitude ≈ 111,000 * cos(latitude) meters
            lat_offset_per_meter = 1.0 / 111000.0
            lon_offset_per_meter = 1.0 / (111000.0 * math.cos(math.radians(user_lat)))
            
            # Random distance between 5-10 meters (not too close, not too far)
            distance = random.uniform(5.0, max_distance_m)
            angle = random.uniform(0, 2 * math.pi)
            
            lat_offset = distance * math.cos(angle) * lat_offset_per_meter
            lon_offset = distance * math.sin(angle) * lon_offset_per_meter
            
            target_location = {
                'latitude': user_lat + lat_offset,
                'longitude': user_lon + lon_offset
            }
            
            map_logger.info(f"[{request_id}] Generated NEW treasure location within 10m of user: {target_location}")
            print(f"🎯 New treasure hunt - X marks the spot {distance:.1f}m from user at ({target_location['latitude']:.6f}, {target_location['longitude']:.6f})")
    
    map_logger.info(f"[{request_id}] Final target location: lat={target_location.get('latitude')}, lon={target_location.get('longitude')}")
    
    try:
        map_logger.info(f"[{request_id}] Calling treasure_map_service.generate_map_piece()...")
        call_start_time = time.time()
        
        map_piece = treasure_map_service.generate_map_piece(
            target_location=target_location,
            piece_number=piece_number,
            total_pieces=2,
            npc_type=npc_type
        )
        
        call_duration = time.time() - call_start_time
        map_logger.info(f"[{request_id}] generate_map_piece() completed in {call_duration:.2f}s")
        
        map_logger.info(f"[{request_id}] Map piece result keys: {list(map_piece.keys()) if isinstance(map_piece, dict) else 'not a dict'}")
        
        if 'error' in map_piece:
            error_msg = map_piece.get('error', 'Unknown error')
            map_logger.error(f"[{request_id}] Map piece generation returned error: {error_msg}")
            # Check if it's a resource limit error - these should be handled gracefully
            error_lower = str(error_msg).lower()
            if 'too large' in error_lower or 'exceeded' in error_lower or 'maximum' in error_lower or 'resource' in error_lower:
                # For resource limit errors, return a map piece without landmarks instead of an error
                map_logger.warning(f"[{request_id}] Resource limit error - returning map piece without landmarks")
                print(f"⚠️ Resource limit error caught in endpoint, returning map piece without landmarks")
                # Generate a basic map piece without landmarks
                lat = target_location.get('latitude', 37.7749)
                lon = target_location.get('longitude', -122.4194)
                import random
                if piece_number == 1:
                    approximate_lat = lat + (random.random() - 0.5) * 0.001
                    approximate_lon = lon + (random.random() - 0.5) * 0.001
                    map_piece = {
                        "piece_number": 1,
                        "hint": "Arr, here be the treasure map, matey! X marks the spot where me gold be buried!",
                        "approximate_latitude": approximate_lat,
                        "approximate_longitude": approximate_lon,
                        "landmarks": [],
                        "is_first_half": True
                    }
                    map_logger.info(f"[{request_id}] Generated fallback map piece (piece 1) without landmarks")
                else:
                    map_piece = {
                        "piece_number": 2,
                        "hint": "Woof! Here's the second half! The treasure is exactly at these coordinates!",
                        "exact_latitude": lat,
                        "exact_longitude": lon,
                        "landmarks": [],
                        "is_second_half": True
                    }
            else:
                # For other errors, still try to return a basic map piece instead of error
                map_logger.warning(f"[{request_id}] Other error in map piece - returning basic map piece without landmarks")
                lat = target_location.get('latitude', 37.7749)
                lon = target_location.get('longitude', -122.4194)
                import random
                if piece_number == 1:
                    approximate_lat = lat + (random.random() - 0.5) * 0.001
                    approximate_lon = lon + (random.random() - 0.5) * 0.001
                    map_piece = {
                        "piece_number": 1,
                        "hint": "Arr, here be the treasure map, matey! X marks the spot where me gold be buried!",
                        "approximate_latitude": approximate_lat,
                        "approximate_longitude": approximate_lon,
                        "landmarks": [],
                        "is_first_half": True
                    }
                else:
                    map_piece = {
                        "piece_number": 2,
                        "hint": "Woof! Here's the second half! The treasure is exactly at these coordinates!",
                        "exact_latitude": lat,
                        "exact_longitude": lon,
                        "landmarks": [],
                        "is_second_half": True
                    }
                map_logger.info(f"[{request_id}] Generated fallback map piece (piece {piece_number}) without landmarks")
        
        # Save treasure hunt to database if we have a device_uuid
        treasure_hunt_id = existing_hunt['id'] if existing_hunt else None
        
        if device_uuid and not existing_hunt:
            # This is a NEW treasure hunt - save it to the database
            try:
                import json as json_module
                conn = get_db_connection()
                cursor = conn.cursor()
                
                # Get the actual treasure coordinates from the map piece
                treasure_lat = map_piece.get('exact_latitude') or map_piece.get('approximate_latitude')
                treasure_lon = map_piece.get('exact_longitude') or map_piece.get('approximate_longitude')
                
                # If piece 1, the treasure location is the target (with slight offset added by generate_map_piece)
                # Store the exact target as the treasure location
                if piece_number == 1:
                    treasure_lat = target_location.get('latitude')
                    treasure_lon = target_location.get('longitude')
                
                # Prepare map piece JSON
                map_piece_json = json_module.dumps(map_piece)
                map_piece_1_json = map_piece_json if piece_number == 1 else None
                map_piece_2_json = map_piece_json if piece_number == 2 else None
                
                cursor.execute('''
                    INSERT INTO treasure_hunts (
                        device_uuid, treasure_latitude, treasure_longitude,
                        origin_latitude, origin_longitude,
                        map_piece_1_json, map_piece_2_json,
                        status, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)
                ''', (
                    device_uuid,
                    treasure_lat,
                    treasure_lon,
                    target_location.get('latitude'),
                    target_location.get('longitude'),
                    map_piece_1_json,
                    map_piece_2_json,
                    datetime.utcnow().isoformat()
                ))
                
                treasure_hunt_id = cursor.lastrowid
                conn.commit()
                conn.close()
                
                map_logger.info(f"[{request_id}] Saved new treasure hunt: id={treasure_hunt_id}, device={device_uuid}, treasure=({treasure_lat}, {treasure_lon})")
                print(f"🗺️ Created new treasure hunt #{treasure_hunt_id} for device {device_uuid[:8]}...")
                
            except Exception as e:
                map_logger.error(f"[{request_id}] Error saving treasure hunt: {e}")
                print(f"⚠️ Error saving treasure hunt: {e}")
        
        elif device_uuid and existing_hunt and not existing_hunt.get(f'map_piece_{piece_number}_json'):
            # We have an existing hunt but this piece wasn't saved yet - update it
            try:
                import json as json_module
                conn = get_db_connection()
                cursor = conn.cursor()
                
                map_piece_json = json_module.dumps(map_piece)
                column_name = f'map_piece_{piece_number}_json'
                
                cursor.execute(f'''
                    UPDATE treasure_hunts 
                    SET {column_name} = ?
                    WHERE id = ?
                ''', (map_piece_json, existing_hunt['id']))
                
                conn.commit()
                conn.close()
                
                map_logger.info(f"[{request_id}] Updated treasure hunt #{existing_hunt['id']} with piece {piece_number}")
                
            except Exception as e:
                map_logger.error(f"[{request_id}] Error updating treasure hunt: {e}")
        
        response_data = {
            'npc_id': npc_id,
            'npc_type': npc_type,
            'map_piece': map_piece,
            'message': f"Here's piece {piece_number} of the treasure map!",
            'treasure_hunt_id': treasure_hunt_id
        }
        
        total_duration = time.time() - request_start_time
        map_logger.info(f"[{request_id}] ========== MAP REQUEST SUCCESS ==========")
        map_logger.info(f"[{request_id}] Total duration: {total_duration:.2f}s")
        map_logger.info(f"[{request_id}] Response size: {len(str(response_data))} bytes")
        
        return jsonify(response_data), 200
    except Exception as e:
        error_msg = str(e).lower()
        # Check if it's a resource limit error
        if 'too large' in error_msg or 'exceeded' in error_msg or 'maximum' in error_msg or 'resource' in error_msg:
            # Return a basic map piece instead of an error
            print(f"⚠️ Resource limit exception caught in endpoint, returning map piece without landmarks")
            lat = target_location.get('latitude', 37.7749)
            lon = target_location.get('longitude', -122.4194)
            import random
            if piece_number == 1:
                approximate_lat = lat + (random.random() - 0.5) * 0.001
                approximate_lon = lon + (random.random() - 0.5) * 0.001
                map_piece = {
                    "piece_number": 1,
                    "hint": "Arr, this be the first half o' the map, matey! The treasure be near these waters!",
                    "approximate_latitude": approximate_lat,
                    "approximate_longitude": approximate_lon,
                    "landmarks": [],
                    "is_first_half": True
                }
            else:
                map_piece = {
                    "piece_number": 2,
                    "hint": "Woof! Here's the second half! The treasure is exactly at these coordinates!",
                    "exact_latitude": lat,
                    "exact_longitude": lon,
                    "landmarks": [],
                    "is_second_half": True
                }
            return jsonify({
                'npc_id': npc_id,
                'npc_type': npc_type,
                'map_piece': map_piece,
                'message': f"Here's piece {piece_number} of the treasure map!"
            }), 200
        else:
            return jsonify({'error': f'LLM error: {str(e)}'}), 500

@app.route('/api/map-pieces/combine', methods=['POST'])
def combine_map_pieces():
    """Combine two map pieces into a complete treasure map."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    data = request.json
    piece1 = data.get('piece1')
    piece2 = data.get('piece2')
    
    if not piece1 or not piece2:
        return jsonify({'error': 'Both piece1 and piece2 are required'}), 400
    
    # Combine the pieces
    # Piece 1 has approximate location, Piece 2 has exact location
    exact_lat = piece2.get('exact_latitude') or piece1.get('approximate_latitude')
    exact_lon = piece2.get('exact_longitude') or piece1.get('approximate_longitude')
    
    if not exact_lat or not exact_lon:
        return jsonify({'error': 'Could not determine treasure location from map pieces'}), 400
    
    # Combine landmarks from both pieces
    landmarks = (piece1.get('landmarks', []) + piece2.get('landmarks', [])).copy()
    
    # Remove duplicates
    seen = set()
    unique_landmarks = []
    for landmark in landmarks:
        if landmark not in seen:
            seen.add(landmark)
            unique_landmarks.append(landmark)
    
    combined_map = {
        'map_name': 'Complete Treasure Map',
        'x_marks_the_spot': {
            'latitude': exact_lat,
            'longitude': exact_lon
        },
        'landmarks': unique_landmarks,
        'combined_from_pieces': [piece1.get('piece_number'), piece2.get('piece_number')]
    }
    
    return jsonify({
        'complete_map': combined_map,
        'message': 'Map pieces combined! X marks the spot!'
    }), 200

# ============================================================================
# Admin Story Mode Elements (for admin panel map)
# ============================================================================

@app.route('/api/admin/story-mode-elements', methods=['GET'])
def get_story_mode_elements():
    """Get all story mode elements for the admin panel map.
    
    Returns all active treasure hunts with their story elements:
    - 💀 Skeleton (Captain Bones) - at origin location
    - 🐕 Corgi (Barnaby) - appears in Stage 2+
    - ❌ Treasure X - the target treasure location
    - 🏴‍☠️ Bandit Hideout - appears in Stage 2+
    
    Also includes player info for each hunt.
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Get all active treasure hunts with player info
        cursor.execute('''
            SELECT 
                th.id,
                th.device_uuid,
                th.treasure_latitude,
                th.treasure_longitude,
                th.origin_latitude,
                th.origin_longitude,
                th.current_stage,
                th.corgi_latitude,
                th.corgi_longitude,
                th.bandit_latitude,
                th.bandit_longitude,
                th.created_at,
                th.status,
                p.player_name
            FROM treasure_hunts th
            LEFT JOIN players p ON th.device_uuid = p.device_uuid
            WHERE th.status = 'active'
            ORDER BY th.created_at DESC
        ''')
        
        rows = cursor.fetchall()
        conn.close()
        
        story_elements = []
        
        for row in rows:
            hunt_id = row[0]
            device_uuid = row[1]
            treasure_lat = row[2]
            treasure_lon = row[3]
            origin_lat = row[4]
            origin_lon = row[5]
            current_stage = row[6] or 'stage_1'
            corgi_lat = row[7]
            corgi_lon = row[8]
            bandit_lat = row[9]
            bandit_lon = row[10]
            created_at = row[11]
            status = row[12]
            player_name = row[13] or f"Player {device_uuid[:8]}"
            
            hunt_elements = {
                'hunt_id': hunt_id,
                'device_uuid': device_uuid,
                'player_name': player_name,
                'current_stage': current_stage,
                'status': status,
                'created_at': created_at,
                'elements': []
            }
            
            # 💀 Skeleton (Captain Bones) - always at origin location
            if origin_lat and origin_lon:
                hunt_elements['elements'].append({
                    'id': f'skeleton_{hunt_id}',
                    'type': 'skeleton',
                    'name': f'💀 Captain Bones ({player_name})',
                    'latitude': origin_lat,
                    'longitude': origin_lon,
                    'icon': '💀',
                    'description': 'Skeleton NPC - gives first map piece'
                })
            
            # ❌ Treasure X - the target location
            if treasure_lat and treasure_lon:
                hunt_elements['elements'].append({
                    'id': f'treasure_{hunt_id}',
                    'type': 'treasure',
                    'name': f'❌ Treasure X ({player_name})',
                    'latitude': treasure_lat,
                    'longitude': treasure_lon,
                    'icon': '❌',
                    'description': 'X marks the spot!'
                })
            
            # 🐕 Corgi (Barnaby) - appears in Stage 2+
            if current_stage in ['stage_2', 'completed'] and corgi_lat and corgi_lon:
                hunt_elements['elements'].append({
                    'id': f'corgi_{hunt_id}',
                    'type': 'corgi',
                    'name': f'🐕 Barnaby the Corgi ({player_name})',
                    'latitude': corgi_lat,
                    'longitude': corgi_lon,
                    'icon': '🐕',
                    'description': 'Corgi NPC - confesses to taking treasure'
                })
            
            # 🏴‍☠️ Bandit Hideout - appears in Stage 2+
            if current_stage in ['stage_2', 'completed'] and bandit_lat and bandit_lon:
                hunt_elements['elements'].append({
                    'id': f'bandit_{hunt_id}',
                    'type': 'bandit',
                    'name': f'🏴‍☠️ Bandit Hideout ({player_name})',
                    'latitude': bandit_lat,
                    'longitude': bandit_lon,
                    'icon': '🏴‍☠️',
                    'description': 'Where bandits fled with remaining treasure'
                })
            
            story_elements.append(hunt_elements)
        
        # Flatten all elements for easy map display
        all_elements = []
        for hunt in story_elements:
            all_elements.extend(hunt['elements'])
        
        return jsonify({
            'story_elements': all_elements,
            'hunts': story_elements,
            'total_hunts': len(story_elements),
            'total_elements': len(all_elements)
        }), 200
        
    except Exception as e:
        print(f"❌ Error fetching story mode elements: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': f'Failed to fetch story elements: {str(e)}'}), 500


# ============================================================================
# Treasure Hunt Endpoints
# ============================================================================

@app.route('/api/treasure-hunts/<device_uuid>', methods=['GET'])
def get_treasure_hunt(device_uuid: str):
    """Get the active treasure hunt for a device/user.
    
    Returns the saved treasure location and map pieces so the iOS app
    can restore the treasure hunt state without regenerating.
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT id, treasure_latitude, treasure_longitude, 
                   origin_latitude, origin_longitude,
                   map_piece_1_json, map_piece_2_json,
                   status, created_at, completed_at
            FROM treasure_hunts 
            WHERE device_uuid = ? AND status = 'active'
            ORDER BY created_at DESC
            LIMIT 1
        ''', (device_uuid,))
        
        row = cursor.fetchone()
        conn.close()
        
        if not row:
            return jsonify({
                'has_active_hunt': False,
                'message': 'No active treasure hunt found for this device'
            }), 200
        
        # Parse map pieces from JSON
        import json
        map_piece_1 = None
        map_piece_2 = None
        
        if row[5]:  # map_piece_1_json
            try:
                map_piece_1 = json.loads(row[5])
            except json.JSONDecodeError:
                pass
        
        if row[6]:  # map_piece_2_json
            try:
                map_piece_2 = json.loads(row[6])
            except json.JSONDecodeError:
                pass
        
        return jsonify({
            'has_active_hunt': True,
            'treasure_hunt': {
                'id': row[0],
                'treasure_latitude': row[1],
                'treasure_longitude': row[2],
                'origin_latitude': row[3],
                'origin_longitude': row[4],
                'map_piece_1': map_piece_1,
                'map_piece_2': map_piece_2,
                'status': row[7],
                'created_at': row[8],
                'completed_at': row[9]
            }
        }), 200
        
    except Exception as e:
        print(f"❌ Error fetching treasure hunt: {e}")
        return jsonify({'error': f'Failed to fetch treasure hunt: {str(e)}'}), 500


@app.route('/api/treasure-hunts/<device_uuid>', methods=['DELETE'])
def reset_treasure_hunt(device_uuid: str):
    """Reset/delete the active treasure hunt for a device/user.
    
    This allows the user to start a new treasure hunt.
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Mark existing active hunts as cancelled (soft delete)
        cursor.execute('''
            UPDATE treasure_hunts 
            SET status = 'cancelled', completed_at = ?
            WHERE device_uuid = ? AND status = 'active'
        ''', (datetime.utcnow().isoformat(), device_uuid))
        
        affected = cursor.rowcount
        conn.commit()
        conn.close()
        
        if affected > 0:
            print(f"🗑️ Reset {affected} treasure hunt(s) for device {device_uuid[:8]}...")
            return jsonify({
                'success': True,
                'message': f'Reset {affected} active treasure hunt(s)',
                'hunts_reset': affected
            }), 200
        else:
            return jsonify({
                'success': True,
                'message': 'No active treasure hunts to reset',
                'hunts_reset': 0
            }), 200
        
    except Exception as e:
        print(f"❌ Error resetting treasure hunt: {e}")
        return jsonify({'error': f'Failed to reset treasure hunt: {str(e)}'}), 500


@app.route('/api/treasure-hunts/<device_uuid>/complete', methods=['POST'])
def complete_treasure_hunt(device_uuid: str):
    """Mark the active treasure hunt as completed (user found the treasure)."""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            UPDATE treasure_hunts 
            SET status = 'completed', completed_at = ?
            WHERE device_uuid = ? AND status = 'active'
        ''', (datetime.utcnow().isoformat(), device_uuid))
        
        affected = cursor.rowcount
        conn.commit()
        conn.close()
        
        if affected > 0:
            print(f"🎉 Completed treasure hunt for device {device_uuid[:8]}!")
            return jsonify({
                'success': True,
                'message': 'Congratulations! Treasure hunt completed!',
                'hunts_completed': affected
            }), 200
        else:
            return jsonify({
                'success': False,
                'message': 'No active treasure hunt to complete',
                'hunts_completed': 0
            }), 404
        
    except Exception as e:
        print(f"❌ Error completing treasure hunt: {e}")
        return jsonify({'error': f'Failed to complete treasure hunt: {str(e)}'}), 500


# ============================================================================
# NPC Management Endpoints
# ============================================================================

@app.route('/api/npcs', methods=['GET'])
def get_npcs():
    """Get all NPCs."""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT 
                id,
                name,
                npc_type,
                latitude,
                longitude,
                created_at,
                created_by,
                ar_origin_latitude,
                ar_origin_longitude,
                ar_offset_x,
                ar_offset_y,
                ar_offset_z,
                ar_placement_timestamp
            FROM npcs
            ORDER BY created_at DESC
        ''')
        
        rows = cursor.fetchall()
        conn.close()
        
        npcs = [{
            'id': row['id'],
            'name': row['name'],
            'npc_type': row['npc_type'],
            'latitude': row['latitude'],
            'longitude': row['longitude'],
            'created_at': row['created_at'],
            'created_by': row['created_by'],
            'ar_origin_latitude': row['ar_origin_latitude'],
            'ar_origin_longitude': row['ar_origin_longitude'],
            'ar_offset_x': row['ar_offset_x'],
            'ar_offset_y': row['ar_offset_y'],
            'ar_offset_z': row['ar_offset_z'],
            'ar_placement_timestamp': row['ar_placement_timestamp']
        } for row in rows]
        
        return jsonify(npcs)
    
    except Exception as e:
        return jsonify({'error': str(e), 'type': type(e).__name__}), 500

@app.route('/api/npcs/<npc_id>', methods=['GET'])
def get_npc(npc_id: str):
    """Get a specific NPC by ID."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('''
        SELECT 
            id,
            name,
            npc_type,
            latitude,
            longitude,
            created_at,
            created_by,
            ar_origin_latitude,
            ar_origin_longitude,
            ar_offset_x,
            ar_offset_y,
            ar_offset_z,
            ar_placement_timestamp
        FROM npcs
        WHERE id = ?
    ''', (npc_id,))
    
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        return jsonify({'error': 'NPC not found'}), 404
    
    return jsonify({
        'id': row['id'],
        'name': row['name'],
        'npc_type': row['npc_type'],
        'latitude': row['latitude'],
        'longitude': row['longitude'],
        'created_at': row['created_at'],
        'created_by': row['created_by'],
        'ar_origin_latitude': row['ar_origin_latitude'],
        'ar_origin_longitude': row['ar_origin_longitude'],
        'ar_offset_x': row['ar_offset_x'],
        'ar_offset_y': row['ar_offset_y'],
        'ar_offset_z': row['ar_offset_z'],
        'ar_placement_timestamp': row['ar_placement_timestamp']
    })

@app.route('/api/npcs', methods=['POST'])
def create_npc():
    """Create a new NPC."""
    data = request.json
    
    required_fields = ['id', 'name', 'npc_type', 'latitude', 'longitude']
    for field in required_fields:
        if field not in data:
            return jsonify({'error': f'Missing required field: {field}'}), 400
    
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            INSERT INTO npcs (
                id, name, npc_type, latitude, longitude, created_at, created_by,
                ar_origin_latitude, ar_origin_longitude,
                ar_offset_x, ar_offset_y, ar_offset_z, ar_placement_timestamp
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            data['id'],
            data['name'],
            data['npc_type'],
            data['latitude'],
            data['longitude'],
            datetime.utcnow().isoformat(),
            data.get('created_by', 'unknown'),
            data.get('ar_origin_latitude'),
            data.get('ar_origin_longitude'),
            data.get('ar_offset_x'),
            data.get('ar_offset_y'),
            data.get('ar_offset_z'),
            data.get('ar_placement_timestamp', datetime.utcnow().isoformat())
        ))
        
        conn.commit()
        
        # Get the created NPC
        cursor.execute('''
            SELECT 
                id, name, npc_type, latitude, longitude, created_at, created_by,
                ar_origin_latitude, ar_origin_longitude,
                ar_offset_x, ar_offset_y, ar_offset_z, ar_placement_timestamp
            FROM npcs
            WHERE id = ?
        ''', (data['id'],))
        
        row = cursor.fetchone()
        conn.close()
        
        if not row:
            return jsonify({'error': 'Failed to retrieve created NPC'}), 500
        
        # Broadcast new NPC to all connected clients
        npc_data = {
            'id': row['id'],
            'name': row['name'],
            'npc_type': row['npc_type'],
            'latitude': row['latitude'],
            'longitude': row['longitude'],
            'created_at': row['created_at'],
            'created_by': row['created_by'],
            'ar_origin_latitude': row['ar_origin_latitude'],
            'ar_origin_longitude': row['ar_origin_longitude'],
            'ar_offset_x': row['ar_offset_x'],
            'ar_offset_y': row['ar_offset_y'],
            'ar_offset_z': row['ar_offset_z'],
            'ar_placement_timestamp': row['ar_placement_timestamp']
        }
        
        socketio.emit('npc_created', npc_data)
        
        return jsonify({
            'id': data['id'],
            'message': 'NPC created successfully'
        }), 201
        
    except sqlite3.IntegrityError as e:
        conn.close()
        return jsonify({'error': 'NPC with this ID already exists'}), 409
    except Exception as e:
        conn.close()
        import traceback
        error_trace = traceback.format_exc()
        print(f"❌ Error creating NPC: {str(e)}")
        print(f"Traceback: {error_trace}")
        return jsonify({'error': f'Internal server error: {str(e)}'}), 500

@app.route('/api/npcs/<npc_id>', methods=['PUT', 'PATCH'])
def update_npc(npc_id: str):
    """Update an NPC's location or other properties."""
    data = request.json
    
    if not data:
        return jsonify({'error': 'No data provided'}), 400
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if NPC exists
    cursor.execute('SELECT id FROM npcs WHERE id = ?', (npc_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'NPC not found'}), 404
    
    # Build update query dynamically based on provided fields
    updates = []
    params = []
    
    updateable_fields = [
        'name', 'npc_type', 'latitude', 'longitude',
        'ar_origin_latitude', 'ar_origin_longitude',
        'ar_offset_x', 'ar_offset_y', 'ar_offset_z', 'ar_placement_timestamp'
    ]
    
    for field in updateable_fields:
        if field in data:
            updates.append(f'{field} = ?')
            params.append(data[field])
    
    if not updates:
        conn.close()
        return jsonify({'error': 'No valid fields to update'}), 400
    
    params.append(npc_id)
    
    cursor.execute(f'''
        UPDATE npcs
        SET {', '.join(updates)}
        WHERE id = ?
    ''', params)
    
    conn.commit()
    
    # Get updated NPC
    cursor.execute('''
        SELECT 
            id, name, npc_type, latitude, longitude, created_at, created_by,
            ar_origin_latitude, ar_origin_longitude,
            ar_offset_x, ar_offset_y, ar_offset_z, ar_placement_timestamp
        FROM npcs
        WHERE id = ?
    ''', (npc_id,))
    
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        return jsonify({'error': 'Failed to retrieve updated NPC'}), 500
    
    # Broadcast NPC update to all connected clients
    npc_data = {
        'id': row['id'],
        'name': row['name'],
        'npc_type': row['npc_type'],
        'latitude': row['latitude'],
        'longitude': row['longitude'],
        'created_at': row['created_at'],
        'created_by': row['created_by'],
        'ar_origin_latitude': row['ar_origin_latitude'],
        'ar_origin_longitude': row['ar_origin_longitude'],
        'ar_offset_x': row['ar_offset_x'],
        'ar_offset_y': row['ar_offset_y'],
        'ar_offset_z': row['ar_offset_z'],
        'ar_placement_timestamp': row['ar_placement_timestamp']
    }
    
    socketio.emit('npc_updated', npc_data)
    
    return jsonify({
        'id': npc_id,
        'message': 'NPC updated successfully'
    }), 200

@app.route('/api/npcs/<npc_id>', methods=['DELETE'])
def delete_npc(npc_id: str):
    """Delete an NPC."""
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if NPC exists
    cursor.execute('SELECT id FROM npcs WHERE id = ?', (npc_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'NPC not found'}), 404
    
    # Delete the NPC
    cursor.execute('DELETE FROM npcs WHERE id = ?', (npc_id,))
    deleted = cursor.rowcount
    
    conn.commit()
    conn.close()
    
    if deleted == 0:
        return jsonify({'error': 'Failed to delete NPC'}), 500
    
    # Broadcast NPC deletion to all connected clients
    socketio.emit('npc_deleted', {
        'npc_id': npc_id
    })
    
    return jsonify({
        'npc_id': npc_id,
        'message': 'NPC deleted successfully'
    }), 200

def ollama_keepalive():
    """Background thread to keep Ollama model loaded in memory.
    Sends periodic requests to prevent model from being unloaded."""
    # Get Ollama base URL from environment or use default
    ollama_url = os.getenv("LLM_BASE_URL", "http://localhost:11434")
    if not ollama_url or "localhost" in ollama_url or "127.0.0.1" in ollama_url:
        # In Docker, use the service name
        ollama_url = os.getenv("LLM_BASE_URL", "http://ollama:11434")
    
    model = os.getenv("LLM_MODEL", "llama3:8b")
    keepalive_interval = 300  # Ping every 5 minutes to keep model loaded
    
    print(f"🔄 Starting Ollama keepalive thread (pinging {ollama_url} every {keepalive_interval}s)...")
    
    while True:
        try:
            time.sleep(keepalive_interval)
            
            # Send a lightweight request to keep the model loaded
            # Use /api/generate with a minimal prompt
            keepalive_payload = {
                "model": model,
                "prompt": "ping",
                "stream": False,
                "options": {
                    "num_predict": 1  # Only generate 1 token
                },
                "keep_alive": -1  # Keep model in memory
            }
            
            try:
                response = requests.post(
                    f"{ollama_url}/api/generate",
                    json=keepalive_payload,
                    timeout=10
                )
                if response.status_code == 200:
                    print(f"✅ Ollama keepalive: Model '{model}' kept alive")
                else:
                    print(f"⚠️ Ollama keepalive: Unexpected status {response.status_code}")
            except requests.exceptions.RequestException as e:
                # Don't spam logs if Ollama is temporarily unavailable
                # Only log if it's been failing for a while
                pass
                
        except Exception as e:
            # Log errors but continue keepalive loop
            print(f"❌ Ollama keepalive error: {e}")
            time.sleep(60)  # Wait 1 minute before retrying on error

@app.route('/api/objects/<object_id>/mark-found', methods=['POST'])
def mark_found_alias(object_id: str):
    """Alias for /found endpoint that iOS client expects."""
    return mark_found(object_id)

@app.route('/api/objects/<object_id>/unmark-found', methods=['POST'])
def unmark_found_alias(object_id: str):
    """Alias for /unmark-found endpoint that iOS client expects."""
    return unmark_found(object_id)

@app.route('/api/objects/bulk', methods=['DELETE'])
def delete_objects_bulk():
    """Delete multiple objects in bulk."""
    data = request.get_json()
    if not data or 'ids' not in data:
        return jsonify({'error': 'Missing ids array in request body'}), 400
    
    object_ids = data['ids']
    if not isinstance(object_ids, list):
        return jsonify({'error': 'ids must be an array'}), 400
    
    if len(object_ids) == 0:
        return jsonify({'message': 'No objects to delete'}), 200
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # Delete associated finds first (foreign key constraint)
        placeholders = ','.join(['?'] * len(object_ids))
        cursor.execute(f'DELETE FROM finds WHERE object_id IN ({placeholders})', object_ids)
        finds_deleted = cursor.rowcount
        
        # Delete the objects
        cursor.execute(f'DELETE FROM objects WHERE id IN ({placeholders})', object_ids)
        objects_deleted = cursor.rowcount
        
        conn.commit()
        
        # Broadcast object deleted events to all connected clients
        for object_id in object_ids:
            socketio.emit('object_deleted', {
                'object_id': object_id
            })
        
        return jsonify({
            'message': f'Successfully deleted {objects_deleted} object(s)',
            'objects_deleted': objects_deleted,
            'finds_deleted': finds_deleted
        }), 200
        
    except sqlite3.Error as e:
        conn.rollback()
        return jsonify({'error': f'Database error: {str(e)}'}), 500
        
    finally:
        conn.close()

if __name__ == '__main__':
    init_db()
    load_location_update_interval_from_db()  # Load persisted location update interval from database
    load_game_mode_from_db()  # Load persisted game mode from database
    load_llm_settings_from_db()  # Load persisted LLM provider/model from database
    port = int(os.environ.get('PORT', 5001))  # Use 5001 as default to avoid conflicts
    # Use get_local_ip() which checks HOST_IP env var first for consistency
    local_ip = get_local_ip()
    
    # Start Ollama keepalive thread if using Ollama provider
    # Check actual provider from llm_service (which may have been loaded from database)
    provider = llm_service.provider.lower() if LLM_AVAILABLE else os.getenv("LLM_PROVIDER", "").lower()
    if provider in ("ollama", "local") and LLM_AVAILABLE:
        keepalive_thread = threading.Thread(target=ollama_keepalive, daemon=True)
        keepalive_thread.start()
        print("🔄 Ollama keepalive thread started")
    
    print("🚀 Starting CacheRaiders API server...")
    print(f"📁 Database: {DB_PATH}")
    print(f"🌐 Server running on:")
    print(f"   - Local: http://localhost:{port}")
    print(f"   - Network: http://{local_ip}:{port}")
    print(f"🔌 WebSocket server enabled")
    print(f"📊 Debug endpoints:")
    print(f"   - Health: http://{local_ip}:{port}/health")
    print(f"   - Connection test: http://{local_ip}:{port}/api/debug/connection-test")
    print(f"   - Network info: http://{local_ip}:{port}/api/debug/network-info")
    print(f"   - Server info: http://{local_ip}:{port}/api/server-info")
    print(f"")
    print(f"💡 To connect from iOS:")
    print(f"   1. Make sure your device is on the same WiFi network")
    print(f"   2. Use the network IP: http://{local_ip}:{port}")
    print(f"   3. Check firewall settings if connection fails")
    
    socketio.run(app, host='0.0.0.0', port=port, debug=True, allow_unsafe_werkzeug=True)

