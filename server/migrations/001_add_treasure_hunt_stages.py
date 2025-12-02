"""
Migration: Add treasure hunt stages support

This migration adds columns to support the multi-stage treasure hunt:
- Stage 1: Find original X, discover IOU
- Stage 2: Meet Corgi, learn about bandits
- Stage 3: Catch bandits, recover treasure

New columns:
- current_stage: Track which stage the player is on
- corgi_latitude/longitude: Where Corgi NPC spawns (within 20m of original X)
- bandit_latitude/longitude: Where bandits fled to (50-150m away)
- iou_discovered_at: When player found the IOU note
- corgi_met_at: When player talked to Corgi
- bandits_caught_at: When player caught the bandits
"""

import sqlite3
import os
from datetime import datetime

DATABASE_PATH = os.path.join(os.path.dirname(__file__), '..', 'cache_raiders.db')


def get_db_connection():
    """Get database connection."""
    conn = sqlite3.connect(DATABASE_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def migrate_up():
    """Apply the migration."""
    print("🔄 Running migration: Add treasure hunt stages...")
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    # Check if columns already exist
    cursor.execute("PRAGMA table_info(treasure_hunts)")
    columns = {row['name'] for row in cursor.fetchall()}
    
    # Add new columns if they don't exist
    new_columns = [
        ("current_stage", "TEXT DEFAULT 'stage_1'"),
        ("corgi_latitude", "REAL"),
        ("corgi_longitude", "REAL"),
        ("bandit_latitude", "REAL"),
        ("bandit_longitude", "REAL"),
        ("iou_discovered_at", "TEXT"),
        ("corgi_met_at", "TEXT"),
        ("bandits_caught_at", "TEXT"),
        ("treasure_amount_recovered", "TEXT"),  # 'full', 'half', 'none'
    ]
    
    for col_name, col_type in new_columns:
        if col_name not in columns:
            try:
                cursor.execute(f"ALTER TABLE treasure_hunts ADD COLUMN {col_name} {col_type}")
                print(f"   ✅ Added column: {col_name}")
            except sqlite3.OperationalError as e:
                if "duplicate column name" in str(e).lower():
                    print(f"   ℹ️ Column already exists: {col_name}")
                else:
                    raise
        else:
            print(f"   ℹ️ Column already exists: {col_name}")
    
    conn.commit()
    conn.close()
    
    print("✅ Migration complete: Treasure hunt stages added")


def migrate_down():
    """Rollback the migration (SQLite doesn't support DROP COLUMN easily)."""
    print("⚠️ SQLite doesn't support dropping columns easily.")
    print("   To rollback, you would need to recreate the table.")
    print("   Skipping rollback for safety.")


if __name__ == "__main__":
    migrate_up()



