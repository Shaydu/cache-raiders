# Database Schema

The CacheRaiders API uses SQLite with two main tables to track objects and who found them.

## Tables

### `objects`
Stores all loot box objects with their locations.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | Unique identifier for the object (UUID) |
| `name` | TEXT | NOT NULL | Display name (e.g., "Chalice", "Treasure Chest") |
| `type` | TEXT | NOT NULL | Object type (e.g., "Chalice", "Temple Relic", "Treasure Chest") |
| `latitude` | REAL | NOT NULL | GPS latitude coordinate |
| `longitude` | REAL | NOT NULL | GPS longitude coordinate |
| `radius` | REAL | NOT NULL | Radius in meters (how close user needs to be) |
| `created_at` | TEXT | NOT NULL | ISO 8601 timestamp when object was created |
| `created_by` | TEXT | | User ID who created the object (optional) |

**Example:**
```sql
INSERT INTO objects VALUES (
    '550e8400-e29b-41d4-a716-446655440000',
    'Ancient Chalice',
    'Chalice',
    37.7749,
    -122.4194,
    5.0,
    '2025-11-23T13:00:00',
    'user123'
);
```

### `finds`
Tracks who found which objects and when.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PRIMARY KEY AUTOINCREMENT | Auto-incrementing find record ID |
| `object_id` | TEXT | NOT NULL, FOREIGN KEY | References `objects.id` |
| `found_by` | TEXT | NOT NULL | User ID (device UUID) who found the object |
| `found_at` | TEXT | NOT NULL | ISO 8601 timestamp when object was found |

**Example:**
```sql
INSERT INTO finds VALUES (
    NULL,  -- auto-increment
    '550e8400-e29b-41d4-a716-446655440000',
    '550e8400-e29b-41d4-a716-446655440001',  -- device UUID
    '2025-11-23T14:30:00'
);
```

### `players`
Maps device UUIDs to player names for display on leaderboards.

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `device_uuid` | TEXT | PRIMARY KEY | Device UUID (same as used in `finds.found_by`) |
| `player_name` | TEXT | NOT NULL | Display name for the player |
| `created_at` | TEXT | NOT NULL | ISO 8601 timestamp when player record was created |
| `updated_at` | TEXT | NOT NULL | ISO 8601 timestamp when player record was last updated |

**Example:**
```sql
INSERT INTO players VALUES (
    '550e8400-e29b-41d4-a716-446655440001',
    'Adventure Seeker',
    '2025-11-23T13:00:00',
    '2025-11-23T15:30:00'
);
```

## Indexes

- `idx_object_id` on `finds(object_id)` - Speeds up lookups of finds by object ID
- `idx_player_name` on `players(player_name)` - Speeds up lookups by player name

## Relationships

- **One-to-Many**: One `object` can have multiple `finds` (if you allow re-finding, though currently the API prevents duplicate finds)
- **Foreign Key**: `finds.object_id` → `objects.id`
- **One-to-One**: One `device_uuid` maps to one `player_name` in the `players` table
- **Logical Link**: `finds.found_by` can be joined with `players.device_uuid` to get player names

## Query Examples

### Get all objects with their found status:
```sql
SELECT 
    o.id,
    o.name,
    o.type,
    o.latitude,
    o.longitude,
    o.radius,
    CASE WHEN f.id IS NOT NULL THEN 1 ELSE 0 END as collected,
    f.found_by,
    f.found_at
FROM objects o
LEFT JOIN finds f ON o.id = f.object_id;
```

### Get all objects found by a specific user:
```sql
SELECT 
    o.id,
    o.name,
    o.type,
    f.found_at
FROM finds f
JOIN objects o ON f.object_id = o.id
WHERE f.found_by = 'user123'
ORDER BY f.found_at DESC;
```

### Get statistics:
```sql
-- Total objects
SELECT COUNT(*) FROM objects;

-- Found objects
SELECT COUNT(DISTINCT object_id) FROM finds;

-- Top finders (with player names)
SELECT 
    COALESCE(p.player_name, f.found_by) as user,
    COUNT(*) as count
FROM finds f
LEFT JOIN players p ON f.found_by = p.device_uuid
GROUP BY f.found_by
ORDER BY count DESC
LIMIT 10;
```

### Get or update player name:
```sql
-- Get player name for a device UUID
SELECT player_name FROM players WHERE device_uuid = '550e8400-e29b-41d4-a716-446655440001';

-- Update player name
UPDATE players 
SET player_name = 'New Name', updated_at = '2025-11-23T16:00:00'
WHERE device_uuid = '550e8400-e29b-41d4-a716-446655440001';

-- Create new player
INSERT INTO players (device_uuid, player_name, created_at, updated_at)
VALUES ('550e8400-e29b-41d4-a716-446655440001', 'Player Name', '2025-11-23T13:00:00', '2025-11-23T13:00:00');
```

## Data Types

- **TEXT**: Used for IDs, names, types, timestamps (ISO 8601 strings), and user IDs
- **REAL**: Used for GPS coordinates (latitude/longitude) and radius (meters)
- **INTEGER**: Used for auto-incrementing primary keys

## Notes

- Timestamps are stored as ISO 8601 strings (e.g., `2025-11-23T13:00:00`)
- Object IDs should be UUIDs to ensure uniqueness
- The API prevents duplicate finds for the same object (enforced in application logic)
- User IDs are device UUIDs (from iOS `identifierForVendor`)
- Player names are optional - if not set, the device UUID is used for display
- The `players` table allows users to set display names that appear on leaderboards
- When querying top finders, the API joins `finds` with `players` to show player names instead of UUIDs



