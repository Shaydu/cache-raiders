#!/usr/bin/env python3
"""
Seed the database with some shared test objects for AR room testing
"""
import sqlite3
import os
from datetime import datetime

DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

def seed_objects():
    """Add some test objects to the database"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Test objects - using coordinates that should be visible in AR
    # These are placed at reasonable distances for testing
    test_objects = [
        {
            'id': 'shared-chalice-001',
            'name': 'Shared Golden Chalice',
            'type': 'Chalice',
            'latitude': 40.0758,  # Near your location
            'longitude': -105.3008,
            'radius': 5.0
        },
        {
            'id': 'shared-treasure-001',
            'name': 'Shared Treasure Chest',
            'type': 'Treasure Chest',
            'latitude': 40.0759,
            'longitude': -105.3009,
            'radius': 5.0
        },
        {
            'id': 'shared-relic-001',
            'name': 'Shared Temple Relic',
            'type': 'Temple Relic',
            'latitude': 40.0760,
            'longitude': -105.3010,
            'radius': 5.0
        },
        {
            'id': 'shared-chalice-002',
            'name': 'Ancient Chalice',
            'type': 'Chalice',
            'latitude': 40.0757,
            'longitude': -105.3007,
            'radius': 5.0
        },
        {
            'id': 'shared-treasure-002',
            'name': 'Pirate Treasure',
            'type': 'Treasure Chest',
            'latitude': 40.0761,
            'longitude': -105.3011,
            'radius': 5.0
        }
    ]
    
    created_count = 0
    skipped_count = 0
    
    for obj in test_objects:
        try:
            cursor.execute('''
                INSERT INTO objects (id, name, type, latitude, longitude, radius, created_at, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                obj['id'],
                obj['name'],
                obj['type'],
                obj['latitude'],
                obj['longitude'],
                obj['radius'],
                datetime.utcnow().isoformat(),
                'seed-script'
            ))
            created_count += 1
            print(f"✅ Created: {obj['name']} ({obj['id']})")
        except sqlite3.IntegrityError:
            skipped_count += 1
            print(f"⏭️  Skipped (already exists): {obj['name']} ({obj['id']})")
    
    conn.commit()
    conn.close()
    
    print(f"\n📊 Summary:")
    print(f"   Created: {created_count} objects")
    print(f"   Skipped: {skipped_count} objects (already exist)")
    print(f"   Total objects in database: {created_count + skipped_count}")

if __name__ == "__main__":
    print("🌱 Seeding shared objects into database...")
    print("=" * 60)
    seed_objects()
    print("=" * 60)
    print("✅ Seeding complete!")










