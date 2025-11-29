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
from datetime import datetime
from typing import Optional, List, Dict
from dotenv import load_dotenv

# Load environment variables from .env file (never commit this file!)
load_dotenv()

# Import LLM service
try:
    from llm_service import llm_service
    LLM_AVAILABLE = True
except ImportError as e:
    print(f"⚠️ LLM service not available: {e}")
    LLM_AVAILABLE = False
    llm_service = None

app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)  # Enable CORS for iOS app
# Use 'threading' instead of 'eventlet' for Python 3.12 compatibility
# Configure Socket.IO with explicit ping/pong settings for better compatibility
socketio = SocketIO(
    app, 
    cors_allowed_origins="*", 
    async_mode='threading',
    ping_interval=25,  # Server sends ping every 25 seconds
    ping_timeout=10    # Wait 10 seconds for pong response
)  # Enable WebSocket support

# Database file path
DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

# In-memory store for user locations (device_uuid -> latest location)
# This allows the web map to show where users are currently located
user_locations: Dict[str, Dict] = {}

# Location update interval setting (in milliseconds, default 1000ms = 1 second)
location_update_interval_ms: int = 1000

# Track connected WebSocket clients (session_id -> device_uuid)
# Also track reverse mapping (device_uuid -> set of session_ids) for multiple connections
connected_clients: Dict[str, str] = {}  # session_id -> device_uuid
client_sessions: Dict[str, set] = {}  # device_uuid -> set of session_ids

def get_local_ip():
    """Get the local network IP address."""
    # First, check if HOST_IP environment variable is set (useful for Docker)
    host_ip = os.environ.get('HOST_IP')
    if host_ip:
        print(f"🌐 Using HOST_IP from environment: {host_ip}")
        return host_ip
    
    # Try to get IP from all network interfaces using socket
    try:
        import socket
        # Get hostname to determine local IP
        hostname = socket.gethostname()
        # Try to get IP from hostname
        try:
            ip = socket.gethostbyname(hostname)
            if ip and not ip.startswith('127.'):
                print(f"🌐 Detected IP from hostname {hostname}: {ip}")
                return ip
        except socket.gaierror:
            pass
        
        # Fallback: Connect to a remote address to determine local IP
        # This doesn't actually send data, just determines the route
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # Connect to a public DNS server (doesn't actually connect)
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            if ip and not ip.startswith('127.'):
                print(f"🌐 Detected IP via socket connection: {ip}")
                return ip
        except Exception:
            pass
        finally:
            s.close()
    except Exception as e:
        print(f"⚠️ Error detecting IP: {e}")
    
    # Last resort: return localhost
    print("⚠️ Could not detect network IP, using 127.0.0.1")
    return '127.0.0.1'

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
        ('ar_placement_timestamp', 'TEXT')
    ]
    
    for column_name, column_type in optional_columns:
        try:
            cursor.execute(f'ALTER TABLE objects ADD COLUMN {column_name} {column_type}')
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
                    INSERT INTO objects (id, name, type, latitude, longitude, radius, created_at, created_by, grounding_height)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (
                    data['id'],
                    data['name'],
                    data['type'],
                    data['latitude'],
                    data['longitude'],
                    data['radius'],
                    datetime.utcnow().isoformat(),
                    data.get('created_by', 'unknown'),
                    data.get('grounding_height')  # Optional - can be None
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
            
            # Check if already found
            cursor.execute('SELECT id, found_by FROM finds WHERE object_id = ?', (object_id,))
            existing_find = cursor.fetchone()
            
            if existing_find:
                # Object is already found - update the found_by field if different
                existing_found_by = existing_find[1] if len(existing_find) > 1 else None
                if existing_found_by != found_by:
                    # Update the found_by field
                    found_at = datetime.utcnow().isoformat()
                    cursor.execute('''
                        UPDATE finds 
                        SET found_by = ?, found_at = ?
                        WHERE object_id = ?
                    ''', (found_by, found_at, object_id))
                    conn.commit()
                    print(f"✅ Updated found_by for object {object_id}: {existing_found_by} -> {found_by}")
                    
                    # Broadcast update event
                    try:
                        socketio.emit('object_collected', {
                            'object_id': object_id,
                            'found_by': found_by,
                            'found_at': found_at
                        })
                    except Exception as emit_error:
                        print(f"⚠️ Warning: Failed to emit object_collected event: {emit_error}")
                    
                    return jsonify({
                        'object_id': object_id,
                        'found_by': found_by,
                        'message': 'Object found_by updated (object was already found)'
                    }), 200
                else:
                    # Already found by the same user - return success
                    return jsonify({
                        'object_id': object_id,
                        'found_by': found_by,
                        'message': 'Object already found by this user'
                    }), 200
            
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
    conn.close()
    
    players = [{
        'device_uuid': row['device_uuid'],
        'player_name': row['player_name'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
        'find_count': row['find_count']
    } for row in rows]
    
    return jsonify(players)

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
    return send_from_directory(os.path.dirname(__file__), 'admin.html')

@app.route('/api/server-info', methods=['GET'])
def get_server_info():
    """Get server network information including IP address."""
    # Log access for debugging
    print(f"📡 Server info requested from {request.remote_addr} (Host: {request.host})")
    
    port = int(os.environ.get('PORT', 5001))
    local_ip = get_local_ip()
    
    # Get the host from the request to determine what URL was used
    host = request.host.split(':')[0] if ':' in request.host else request.host
    
    # If we got a Docker container IP, try to use the request's host if it's not localhost
    if local_ip.startswith('172.') or (local_ip.startswith('10.') and local_ip != '127.0.0.1'):
        # If accessed via a non-localhost address, use that
        if host not in ['localhost', '127.0.0.1', '0.0.0.0']:
            # Try to extract IP from host if it's an IP address
            try:
                socket.inet_aton(host)  # Validates IP address
                local_ip = host
            except:
                pass
    
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
    local_ip = get_local_ip()
    
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
    host = request.args.get('host', get_local_ip())
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
    local_ip = get_local_ip()
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

@app.route('/api/llm/test', methods=['GET'])
def test_llm():
    """Test if LLM service is working."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    result = llm_service.test_connection()
    return jsonify(result), 200 if result['status'] == 'success' else 500

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
        
        # Handle both old string return and new dict return for backward compatibility
        if isinstance(result, dict):
            response_text = result.get('response', '')
            placement = result.get('placement')
            
            response_data = {
                'npc_id': npc_id,
                'response': response_text,
                'npc_name': npc_name
            }
            
            if placement:
                response_data['placement'] = placement
            
            return jsonify(response_data), 200
        else:
            # Backward compatibility: if it returns a string
            return jsonify({
                'npc_id': npc_id,
                'response': result,
                'npc_name': npc_name
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
    """Set the location update interval in milliseconds."""
    global location_update_interval_ms
    
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
    
    # Broadcast the new interval to all connected clients via WebSocket
    socketio.emit('location_update_interval_changed', {
        'interval_ms': location_update_interval_ms,
        'interval_seconds': location_update_interval_ms / 1000.0
    }, broadcast=True)
    
    print(f"📍 Location update interval changed to {location_update_interval_ms}ms ({location_update_interval_ms/1000.0}s)")
    
    return jsonify({
        'interval_ms': location_update_interval_ms,
        'interval_seconds': location_update_interval_ms / 1000.0,
        'message': f'Location update interval set to {location_update_interval_ms/1000.0} seconds'
    })

@app.route('/api/npcs/<npc_id>/map-piece', methods=['GET', 'POST'])
def get_npc_map_piece(npc_id: str):
    """Get a treasure map piece from an NPC (skeleton has first half, corgi has second half)."""
    if not LLM_AVAILABLE:
        return jsonify({'error': 'LLM service not available'}), 503
    
    # Determine which NPC and which piece
    npc_type = "skeleton" if "skeleton" in npc_id.lower() else "corgi"
    piece_number = 1 if npc_type == "skeleton" else 2
    
    # Get target location from request (POST body or query params)
    target_location = {}
    if request.method == 'POST' and request.json:
        target_location = request.json.get('target_location', {})
    elif request.method == 'GET':
        # Try to get from query params
        lat = request.args.get('latitude')
        lon = request.args.get('longitude')
        if lat and lon:
            target_location = {'latitude': float(lat), 'longitude': float(lon)}
    
    # If no target provided, use a default location (for testing)
    if not target_location.get('latitude') or not target_location.get('longitude'):
        # Default to San Francisco for testing
        target_location = {
            'latitude': 37.7749,
            'longitude': -122.4194
        }
    
    try:
        map_piece = llm_service.generate_map_piece(
            target_location=target_location,
            piece_number=piece_number,
            total_pieces=2,
            npc_type=npc_type
        )
        
        if 'error' in map_piece:
            return jsonify(map_piece), 400
        
        return jsonify({
            'npc_id': npc_id,
            'npc_type': npc_type,
            'map_piece': map_piece,
            'message': f"Here's piece {piece_number} of the treasure map!"
        }), 200
    except Exception as e:
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

if __name__ == '__main__':
    init_db()
    port = int(os.environ.get('PORT', 5001))  # Use 5001 as default to avoid conflicts
    local_ip = get_local_ip()
    
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

