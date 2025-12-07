#!/usr/bin/env python3
"""
Migration: Add ar_placement_heading field to objects table

This migration adds a new field to store the compass heading when an object
was placed, enabling consistent object orientation across different users.
"""

import sqlite3
import os
import sys

def migrate_database(db_path):
    """Add ar_placement_heading column to objects table"""

    if not os.path.exists(db_path):
        print(f"❌ Database file not found: {db_path}")
        return False

    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        # Check if column already exists (idempotent migration)
        cursor.execute("PRAGMA table_info(objects)")
        columns = cursor.fetchall()
        column_names = [col[1] for col in columns]

        if 'ar_placement_heading' in column_names:
            print("✅ ar_placement_heading column already exists - skipping migration")
            conn.close()
            return True

        # Add the new column
        print("📍 Adding ar_placement_heading column to objects table...")
        cursor.execute("""
            ALTER TABLE objects
            ADD COLUMN ar_placement_heading REAL
        """)

        conn.commit()
        conn.close()

        print("✅ Successfully added ar_placement_heading column")
        print("   This field stores compass heading (degrees) when object was placed")
        print("   Used for consistent object orientation across different users")

        return True

    except Exception as e:
        print(f"❌ Migration failed: {e}")
        return False

if __name__ == "__main__":
    # Default database path
    db_path = os.path.join(os.path.dirname(__file__), '..', 'cache_raiders.db')

    if len(sys.argv) > 1:
        db_path = sys.argv[1]

    print("🗄️ Running migration: Add ar_placement_heading field")
    print(f"📍 Database: {db_path}")

    success = migrate_database(db_path)
    sys.exit(0 if success else 1)





