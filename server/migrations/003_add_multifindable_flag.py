"""
Migration: Add multifindable flag for configurable item visibility

This migration adds a multifindable flag to the objects table that controls
whether items disappear for everyone when found (single-find) or only for
the user who found them (multi-findable).

Behavior:
- multifindable = 1: Item disappears only for the user who found it, remains visible to others
- multifindable = 0: Item disappears for everyone once found (traditional behavior)

Default behavior by placement type:
- NFC-placed items: multifindable = 1 (multi-findable by default)
- Map/admin-placed items: multifindable = 0 (single-find by default, configurable)

New column:
- multifindable: INTEGER field (0 or 1) with default based on placement type
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
    print("🔄 Running migration: Add multifindable flag...")

    conn = get_db_connection()
    cursor = conn.cursor()

    # Check if column already exists
    cursor.execute("PRAGMA table_info(objects)")
    columns = {row['name'] for row in cursor.fetchall()}

    # Add new column if it doesn't exist
    new_column = "multifindable"
    if new_column not in columns:
        try:
            # Add column with default value of 0 (single-find by default)
            cursor.execute(f"ALTER TABLE objects ADD COLUMN {new_column} INTEGER DEFAULT 0")
            print(f"   ✅ Added column: {new_column}")

            # Set NFC-placed items to be multifindable by default
            # NFC items typically have nfc_tag_id set
            cursor.execute("""
                UPDATE objects
                SET multifindable = 1
                WHERE nfc_tag_id IS NOT NULL AND nfc_tag_id != ''
            """)
            updated_count = cursor.rowcount
            print(f"   ✅ Set {updated_count} NFC-placed items as multifindable")

        except sqlite3.OperationalError as e:
            if "duplicate column name" in str(e).lower():
                print(f"   ℹ️ Column already exists: {new_column}")
            else:
                raise
    else:
        print(f"   ℹ️ Column already exists: {new_column}")

    conn.commit()
    conn.close()

    print("✅ Migration complete: multifindable flag added")


def migrate_down():
    """Rollback the migration (SQLite doesn't support DROP COLUMN easily)."""
    print("⚠️ SQLite doesn't support dropping columns easily.")
    print("   To rollback, you would need to recreate the table.")
    print("   Skipping rollback for safety.")


if __name__ == "__main__":
    migrate_up()



