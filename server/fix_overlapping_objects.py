#!/usr/bin/env python3
"""
Fix overlapping objects in the database by moving them apart
Ensures minimum 2 meter separation between all objects
"""
import sqlite3
import os
import math
from collections import defaultdict

DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

def haversine_distance(lat1, lon1, lat2, lon2):
    """Calculate distance between two GPS coordinates in meters"""
    R = 6371000  # Earth radius in meters
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    
    a = math.sin(delta_phi/2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda/2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
    
    return R * c

def move_object_away(lat, lon, min_distance=2.0):
    """Move an object away from origin by minimum distance in a random direction"""
    # Random bearing (0-360 degrees)
    import random
    bearing = random.uniform(0, 360) * math.pi / 180.0
    
    # Convert distance to degrees (rough approximation)
    lat_offset = (min_distance / 111000.0) * math.cos(bearing)
    lon_offset = (min_distance / (111000.0 * abs(math.cos(math.radians(lat))))) * math.sin(bearing)
    
    return lat + lat_offset, lon + lon_offset

def fix_overlapping_objects():
    """Find and fix overlapping objects"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Get all objects
    cursor.execute("SELECT id, name, latitude, longitude FROM objects")
    all_objects = cursor.fetchall()
    
    # Group objects by location (rounded to avoid floating point issues)
    location_groups = defaultdict(list)
    for obj in all_objects:
        # Round to 6 decimal places (~0.1 meter precision)
        key = (round(obj[2], 6), round(obj[3], 6))
        location_groups[key].append(obj)
    
    # Find groups with multiple objects (overlaps)
    overlaps_found = 0
    objects_fixed = 0
    
    for (lat, lon), objects in location_groups.items():
        if len(objects) > 1:
            overlaps_found += 1
            print(f"\n⚠️ Found {len(objects)} objects at ({lat:.6f}, {lon:.6f}):")
            
            # Keep first object at original location
            keep_object = objects[0]
            print(f"   Keeping: {keep_object[1]} (ID: {keep_object[0]}) at original location")
            
            # Move other objects away
            for i, obj in enumerate(objects[1:], start=1):
                new_lat, new_lon = move_object_away(lat, lon, min_distance=2.0 + (i * 0.5))
                
                cursor.execute("""
                    UPDATE objects 
                    SET latitude = ?, longitude = ?
                    WHERE id = ?
                """, (new_lat, new_lon, obj[0]))
                
                objects_fixed += 1
                print(f"   Moved: {obj[1]} (ID: {obj[0]}) to ({new_lat:.6f}, {new_lon:.6f})")
    
    conn.commit()
    
    # Verify fix
    cursor.execute("""
        SELECT 
            o1.id as id1, o1.name as name1,
            o2.id as id2, o2.name as name2,
            (
                6371000 * acos(
                    cos(radians(o1.latitude)) * cos(radians(o2.latitude)) *
                    cos(radians(o2.longitude) - radians(o1.longitude)) +
                    sin(radians(o1.latitude)) * sin(radians(o2.latitude))
                )
            ) as distance_meters
        FROM objects o1
        JOIN objects o2 ON o1.id < o2.id
        WHERE (
            6371000 * acos(
                cos(radians(o1.latitude)) * cos(radians(o2.latitude)) *
                cos(radians(o2.longitude) - radians(o1.longitude)) +
                sin(radians(o1.latitude)) * sin(radians(o2.latitude))
            )
        ) < 2.0
    """)
    
    remaining_overlaps = cursor.fetchall()
    
    conn.close()
    
    print(f"\n📊 Summary:")
    print(f"   Overlap groups found: {overlaps_found}")
    print(f"   Objects moved: {objects_fixed}")
    if remaining_overlaps:
        print(f"   ⚠️ Warning: {len(remaining_overlaps)} overlaps still remain (may need manual fix)")
    else:
        print(f"   ✅ All objects now have minimum 2m separation!")

if __name__ == "__main__":
    print("🔧 Fixing overlapping objects in database...")
    print("=" * 60)
    fix_overlapping_objects()
    print("=" * 60)
    print("✅ Fix complete!")









