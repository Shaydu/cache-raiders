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

app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)  # Enable CORS for iOS app
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')  # Enable WebSocket support

# Database file path
DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

# In-memory store for user locations (device_uuid -> latest location)
# This allows the web map to show where users are currently located
user_locations: Dict[str, Dict] = {}

def get_db_connection():
    """Get a database connection."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
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
    
    conn.commit()
    conn.close()
    print("✅ Database initialized")

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint."""
    return jsonify({'status': 'healthy', 'timestamp': datetime.utcnow().isoformat()})

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
    data = request.json
    
    required_fields = ['id', 'name', 'type', 'latitude', 'longitude', 'radius']
    for field in required_fields:
        if field not in data:
            return jsonify({'error': f'Missing required field: {field}'}), 400
    
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
        
        # Broadcast new object to all connected clients
        if row:
            socketio.emit('object_created', {
                'id': row['id'],
                'name': row['name'],
                'type': row['type'],
                'latitude': row['latitude'],
                'longitude': row['longitude'],
                'radius': row['radius'],
                'created_at': row['created_at'],
                'created_by': row['created_by'],
                'grounding_height': row['grounding_height'],
                'ar_origin_latitude': row['ar_origin_latitude'] if 'ar_origin_latitude' in row.keys() else None,
                'ar_origin_longitude': row['ar_origin_longitude'] if 'ar_origin_longitude' in row.keys() else None,
                'ar_offset_x': row['ar_offset_x'] if 'ar_offset_x' in row.keys() else None,
                'ar_offset_y': row['ar_offset_y'] if 'ar_offset_y' in row.keys() else None,
                'ar_offset_z': row['ar_offset_z'] if 'ar_offset_z' in row.keys() else None,
                'ar_placement_timestamp': row['ar_placement_timestamp'] if 'ar_placement_timestamp' in row.keys() else None,
                'collected': bool(row['collected']),
                'found_by': row['found_by'],
                'found_at': row['found_at']
            })
        
        return jsonify({
            'id': data['id'],
            'message': 'Object created successfully'
        }), 201
        
    except sqlite3.IntegrityError:
        conn.close()
        return jsonify({'error': 'Object with this ID already exists'}), 409

@app.route('/api/objects/<object_id>/found', methods=['POST'])
def mark_found(object_id: str):
    """Mark an object as found by a user."""
    data = request.json
    found_by = data.get('found_by', 'unknown')
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if object exists
    cursor.execute('SELECT id FROM objects WHERE id = ?', (object_id,))
    if not cursor.fetchone():
        conn.close()
        return jsonify({'error': 'Object not found'}), 404
    
    # Check if already found
    cursor.execute('SELECT id FROM finds WHERE object_id = ?', (object_id,))
    if cursor.fetchone():
        conn.close()
        return jsonify({'error': 'Object already found'}), 409
    
    # Record the find
    found_at = datetime.utcnow().isoformat()
    cursor.execute('''
        INSERT INTO finds (object_id, found_by, found_at)
        VALUES (?, ?, ?)
    ''', (object_id, found_by, found_at))
    
    conn.commit()
    conn.close()
    
    # Broadcast object collected event to all connected clients
    socketio.emit('object_collected', {
        'object_id': object_id,
        'found_by': found_by,
        'found_at': found_at
    })
    
    return jsonify({
        'object_id': object_id,
        'found_by': found_by,
        'message': 'Object marked as found'
    }), 200

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
    conn = get_db_connection()
    cursor = conn.cursor()
    
    cursor.execute('DELETE FROM finds WHERE object_id = ?', (object_id,))
    deleted = cursor.rowcount
    
    conn.commit()
    conn.close()
    
    if deleted == 0:
        return jsonify({'error': 'No find record found for this object'}), 404
    
    # Broadcast object uncollected event to all connected clients
    socketio.emit('object_uncollected', {
        'object_id': object_id
    })
    
    return jsonify({
        'object_id': object_id,
        'message': 'Find record removed'
    }), 200

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
    data = request.json
    
    if not data or 'player_name' not in data:
        return jsonify({'error': 'Missing required field: player_name'}), 400
    
    player_name = data['player_name'].strip()
    if not player_name:
        return jsonify({'error': 'player_name cannot be empty'}), 400
    
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
    
    return jsonify({
        'device_uuid': row['device_uuid'],
        'player_name': row['player_name'],
        'created_at': row['created_at'],
        'updated_at': row['updated_at']
    }), 200

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
    def get_local_ip():
        """Get the local network IP address."""
        # First, check if HOST_IP environment variable is set (useful for Docker)
        host_ip = os.environ.get('HOST_IP')
        if host_ip:
            return host_ip
        
        try:
            # Connect to a remote address to determine local IP
            # This doesn't actually send data, just determines the route
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                # Connect to a public DNS server (doesn't actually connect)
                s.connect(('8.8.8.8', 80))
                ip = s.getsockname()[0]
                
                # If we're in Docker and got a container IP (172.x.x.x or 10.x.x.x), 
                # try to get the host IP from the request's remote address
                if ip.startswith('172.') or ip.startswith('10.') or ip.startswith('192.168.0.') or ip.startswith('192.168.1.'):
                    # Check if we can get the client's IP (which might be the host)
                    client_ip = request.remote_addr
                    if client_ip and not client_ip.startswith('127.'):
                        # If client is on the same network, we can infer the host IP
                        # For now, we'll use the detected IP but log a warning
                        print(f"⚠️ Detected container IP: {ip}, client IP: {client_ip}")
                return ip
            except Exception:
                ip = '127.0.0.1'
            finally:
                s.close()
            return ip
        except Exception:
            return '127.0.0.1'
    
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

@app.route('/api/qrcode', methods=['GET'])
def generate_qrcode():
    """Generate a QR code for the server URL."""
    def get_local_ip():
        """Get the local network IP address."""
        # First, check if HOST_IP is set (useful for Docker containers)
        host_ip = os.environ.get('HOST_IP')
        if host_ip:
            return host_ip
        
        # Otherwise, detect the IP address
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.connect(('8.8.8.8', 80))
                ip = s.getsockname()[0]
            except Exception:
                ip = '127.0.0.1'
            finally:
                s.close()
            return ip
        except Exception:
            return '127.0.0.1'
    
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
    print(f"🔌 Client connected: {request.sid}")
    emit('connected', {'status': 'connected', 'message': 'Successfully connected to CacheRaiders WebSocket'})

@socketio.on('disconnect')
def handle_disconnect():
    """Handle client disconnection."""
    print(f"🔌 Client disconnected: {request.sid}")

@socketio.on('ping')
def handle_ping():
    """Handle ping for keepalive."""
    emit('pong', {'timestamp': datetime.utcnow().isoformat()})

if __name__ == '__main__':
    init_db()
    port = int(os.environ.get('PORT', 5001))  # Use 5001 as default to avoid conflicts
    print("🚀 Starting CacheRaiders API server...")
    print(f"📁 Database: {DB_PATH}")
    print(f"🌐 Server running on http://localhost:{port}")
    print(f"🔌 WebSocket server enabled")
    socketio.run(app, host='0.0.0.0', port=port, debug=True, allow_unsafe_werkzeug=True)

