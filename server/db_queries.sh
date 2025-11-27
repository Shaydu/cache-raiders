#!/bin/bash
# Useful SQLite queries for monitoring the CacheRaiders database

DB_PATH="cache_raiders.db"

echo "=== All Objects ==="
sqlite3 "$DB_PATH" "SELECT id, name, type, latitude, longitude, radius, created_at FROM objects;"

echo -e "\n=== All Finds ==="
sqlite3 "$DB_PATH" "SELECT f.id, f.object_id, o.name, f.found_by, f.found_at FROM finds f JOIN objects o ON f.object_id = o.id;"

echo -e "\n=== Objects with Found Status ==="
sqlite3 "$DB_PATH" "
SELECT 
    o.id,
    o.name,
    o.type,
    CASE WHEN f.id IS NOT NULL THEN 'FOUND' ELSE 'NOT FOUND' END as status,
    f.found_by,
    f.found_at
FROM objects o
LEFT JOIN finds f ON o.id = f.object_id
ORDER BY o.created_at DESC;
"

echo -e "\n=== Statistics ==="
sqlite3 "$DB_PATH" "
SELECT 
    (SELECT COUNT(*) FROM objects) as total_objects,
    (SELECT COUNT(DISTINCT object_id) FROM finds) as found_objects,
    (SELECT COUNT(*) FROM finds) as total_finds;
"

echo -e "\n=== Top Finders ==="
sqlite3 "$DB_PATH" "
SELECT found_by, COUNT(*) as count
FROM finds
GROUP BY found_by
ORDER BY count DESC;
"









