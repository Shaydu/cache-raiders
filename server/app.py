"""
CacheRaiders API Server
Simple REST API for tracking loot box objects, their locations, and who found them.
"""
from flask import Flask, request, jsonify
from flask_cors import CORS
import sqlite3
import os
import math
from datetime import datetime
from typing import Optional, List, Dict

app = Flask(__name__)
CORS(app)  # Enable CORS for iOS app

# Database file path
DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

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
            created_by TEXT
        )
    ''')
    
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
    latitude = request.args.get('latitude', type=float)
    longitude = request.args.get('longitude', type=float)
    radius = request.args.get('radius', type=float, default=10000.0)  # Default 10km
    include_found = request.args.get('include_found', 'false').lower() == 'true'
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    query = '''
        SELECT 
            o.id,
            o.name,
            o.type,
            o.latitude,
            o.longitude,
            o.radius,
            o.created_at,
            o.created_by,
            CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as collected,
            f.found_by,
            f.found_at
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
            objects_dict[obj_id] = {
                'id': row['id'],
                'name': row['name'],
                'type': row['type'],
                'latitude': row['latitude'],
                'longitude': row['longitude'],
                'radius': row['radius'],
                'created_at': row['created_at'],
                'created_by': row['created_by'],
                'collected': bool(row['collected']),
                'found_by': row['found_by'],
                'found_at': row['found_at']
            }
    
    return jsonify(list(objects_dict.values()))

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
            INSERT INTO objects (id, name, type, latitude, longitude, radius, created_at, created_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            data['id'],
            data['name'],
            data['type'],
            data['latitude'],
            data['longitude'],
            data['radius'],
            datetime.utcnow().isoformat(),
            data.get('created_by', 'unknown')
        ))
        
        conn.commit()
        conn.close()
        
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
    cursor.execute('''
        INSERT INTO finds (object_id, found_by, found_at)
        VALUES (?, ?, ?)
    ''', (object_id, found_by, datetime.utcnow().isoformat()))
    
    conn.commit()
    conn.close()
    
    return jsonify({
        'object_id': object_id,
        'found_by': found_by,
        'message': 'Object marked as found'
    }), 200

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
    
    # Top finders
    cursor.execute('''
        SELECT found_by, COUNT(*) as count
        FROM finds
        GROUP BY found_by
        ORDER BY count DESC
        LIMIT 10
    ''')
    top_finders = [{'user': row['found_by'], 'count': row['count']} for row in cursor.fetchall()]
    
    conn.close()
    
    return jsonify({
        'total_objects': total_objects,
        'found_objects': found_objects,
        'unfound_objects': total_objects - found_objects,
        'total_finds': total_finds,
        'top_finders': top_finders
    })

if __name__ == '__main__':
    init_db()
    print("🚀 Starting CacheRaiders API server...")
    print(f"📁 Database: {DB_PATH}")
    app.run(host='0.0.0.0', port=5000, debug=True)

