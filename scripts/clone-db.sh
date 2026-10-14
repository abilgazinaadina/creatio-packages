#!/bin/sh
set -e

BRANCH="$1"
IMAGE_TAG="$2"

if [ -z "$BRANCH" ] || [ -z "$IMAGE_TAG" ]; then
    echo "Usage: clone-db.sh <branch> <image-tag>"
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

SLUG=$(sh "$SCRIPT_DIR/slug.sh" "$BRANCH")

DB_SUFFIX=$(echo "$SLUG" | tr '-' '_')

STAND_DB="stand_${DB_SUFFIX}"
SNAPSHOT_DB="creatio_snap_${IMAGE_TAG}"

echo "----------------------------------------"
echo "Database clone"
echo
echo "Branch:      $BRANCH"
echo "Slug:        $SLUG"
echo "Snapshot:    $SNAPSHOT_DB"
echo "Stand DB:    $STAND_DB"
echo "----------------------------------------"

DB_CONTAINER=$(docker ps -q \
  --filter "label=com.docker.compose.project=day1-stand" \
  --filter "label=com.docker.compose.service=db" \
  | head -n 1)

if [ -z "$DB_CONTAINER" ]; then
    echo "ERROR: PostgreSQL container not found"
    exit 1
fi

echo "PostgreSQL container: $DB_CONTAINER"

# Проверяем, что snapshot существует
SNAPSHOT_EXISTS=$(docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${SNAPSHOT_DB}';")

if [ "$SNAPSHOT_EXISTS" != "1" ]; then
    echo "ERROR: Snapshot database ${SNAPSHOT_DB} does not exist"
    exit 1
fi

# Закрываем подключения к старой stand DB, если она уже существует
docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${STAND_DB}'
      AND pid <> pg_backend_pid();
"

# Удаляем старую БД стенда
docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    DROP DATABASE IF EXISTS ${STAND_DB};
"

# Создаём новую БД за несколько секунд из snapshot
docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    CREATE DATABASE ${STAND_DB}
    TEMPLATE ${SNAPSHOT_DB};
"

echo
echo "Database ${STAND_DB} created successfully"