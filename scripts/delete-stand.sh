#!/bin/sh
set -e

BRANCH="$1"

if [ -z "$BRANCH" ]; then
    echo "Usage: delete-stand.sh <branch>"
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

SLUG=$(sh "$SCRIPT_DIR/slug.sh" "$BRANCH")
DB_SUFFIX=$(echo "$SLUG" | tr '-' '_')

RELEASE_NAME="stand-${SLUG}"
DB_NAME="stand_${DB_SUFFIX}"

REDIS_DB=$(echo -n "$SLUG" \
    | cksum \
    | awk '{print ($1 % 15) + 1}')

echo "----------------------------------------"
echo "Delete stand"
echo
echo "Branch:      $BRANCH"
echo "Slug:        $SLUG"
echo "Release:     $RELEASE_NAME"
echo "Database:    $DB_NAME"
echo "Redis DB:    $REDIS_DB"
echo "----------------------------------------"


echo
echo "1. Removing Helm release..."

if helm status "$RELEASE_NAME" -n stands >/dev/null 2>&1; then
    helm uninstall "$RELEASE_NAME" -n stands
else
    echo "Helm release $RELEASE_NAME not found"
fi


echo
echo "2. Removing database..."

DB_CONTAINER=$(docker ps -q \
  --filter "label=com.docker.compose.project=day1-stand" \
  --filter "label=com.docker.compose.service=db" \
  | head -n 1)

if [ -z "$DB_CONTAINER" ]; then
    echo "ERROR: PostgreSQL container not found"
    exit 1
fi

docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${DB_NAME}'
      AND pid <> pg_backend_pid();
"

docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    DROP DATABASE IF EXISTS ${DB_NAME};
"


echo
echo "3. Cleaning Redis DB..."

REDIS_CONTAINER=$(docker ps -q \
  --filter "label=com.docker.compose.project=day1-stand" \
  --filter "label=com.docker.compose.service=redis" \
  | head -n 1)

if [ -z "$REDIS_CONTAINER" ]; then
    echo "ERROR: Redis container not found"
    exit 1
fi

docker exec "$REDIS_CONTAINER" \
  redis-cli -n "$REDIS_DB" FLUSHDB


echo
echo "========================================"
echo "Stand deleted successfully"
echo
echo "Branch:   $BRANCH"
echo "Release:  $RELEASE_NAME"
echo "Database: $DB_NAME"
echo "Redis DB: $REDIS_DB"
echo "========================================"