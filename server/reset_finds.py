#!/usr/bin/env python3
"""
Reset all objects to unfound status by clearing the finds table
"""
import sqlite3
import os

DB_PATH = os.path.join(os.path.dirname(__file__), 'cache_raiders.db')

def reset_finds():
    """Clear all finds records, making all objects unfound"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Count finds before deletion
    cursor.execute('SELECT COUNT(*) FROM finds')
    finds_count = cursor.fetchone()[0]
    
    # Count objects
    cursor.execute('SELECT COUNT(*) FROM objects')
    objects_count = cursor.fetchone()[0]
    
    # Delete all finds
    cursor.execute('DELETE FROM finds')
    deleted_count = cursor.rowcount
    
    conn.commit()
    conn.close()
    
    print(f"🔄 Reset complete!")
    print(f"   Objects in database: {objects_count}")
    print(f"   Finds removed: {deleted_count}")
    print(f"   All objects are now unfound ✅")

if __name__ == "__main__":
    print("🔄 Resetting all objects to unfound status...")
    print("=" * 60)
    reset_finds()
    print("=" * 60)
    print("✅ Reset complete!")


