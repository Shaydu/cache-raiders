"""
Migration: Add AR world transform support for precise NFC placement

This migration adds support for storing the complete AR world transform
matrix for objects placed via NFC tokens. This enables exact positioning
where users tap in AR space, rather than GPS-based approximations.

New columns:
- ar_world_transform: BLOB field storing the complete AR transform matrix
"""

import sqlite3
import os

DATABASE_PATH = os.path.join(os.path.dirname(__file__), '..', 'cache_raiders.db')


def get_db_connection():
    """Get database connection."""
    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def migrate_up():
    """Apply the migration."""
    print("🔄 Running migration: Add AR world transform support...")

    conn = get_db_connection()
    cursor = conn.cursor()

    # Check if columns already exist
    cursor.execute("PRAGMA table_info(objects)")
    columns = {row['name'] for row in cursor.fetchall()}

    # Add new column if it doesn't exist
    new_column = "ar_world_transform"
    if new_column not in columns:
        try:
            cursor.execute(f"ALTER TABLE objects ADD COLUMN {new_column} BLOB")
            print(f"   ✅ Added column: {new_column}")
        except sqlite3.OperationalError as e:
            if "duplicate column name" in str(e).lower():
                print(f"   ℹ️ Column already exists: {new_column}")
            else:
                raise
    else:
        print(f"   ℹ️ Column already exists: {new_column}")

    conn.commit()
    conn.close()

    print("✅ Migration complete: AR world transform support added")


def migrate_down():
    """Rollback the migration (SQLite doesn't support DROP COLUMN easily)."""
    print("⚠️ SQLite doesn't support dropping columns easily.")
    print("   To rollback, you would need to recreate the table.")
    print("   Skipping rollback for safety.")


if __name__ == "__main__":
    migrate_up()


