#!/bin/sh
set -e

BRANCH="$1"

if [ -z "$BRANCH" ]; then
    echo "Usage: delete-stand.sh <branch>"
    exit 1
fi

NAMESPACE="stands"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

SLUG=$(sh "$SCRIPT_DIR/slug.sh" "$BRANCH")
DB_SUFFIX=$(echo "$SLUG" | tr '-' '_')

RELEASE_NAME="stand-${SLUG}"
DB_NAME="stand_${DB_SUFFIX}"

echo "----------------------------------------"
echo "Delete stand"
echo
echo "Branch:      $BRANCH"
echo "Slug:        $SLUG"
echo "Release:     $RELEASE_NAME"
echo "Database:    $DB_NAME"
echo "----------------------------------------"


# --------------------------------------------------
# Получаем Redis DB ДО удаления Helm release
# --------------------------------------------------

REDIS_DB=""

if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then

    REDIS_DB=$(helm get values "$RELEASE_NAME" \
        -n "$NAMESPACE" \
        -o json 2>/dev/null \
        | sed -n 's/.*"redis":{[^}]*"database":\([0-9][0-9]*\).*/\1/p')

    echo "Redis DB:    ${REDIS_DB:-not found}"

else
    echo "Helm release $RELEASE_NAME not found"
fi


# --------------------------------------------------
# 1. Helm uninstall
# --------------------------------------------------

echo
echo "1. Removing Helm release..."

if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then

    helm uninstall "$RELEASE_NAME" \
        -n "$NAMESPACE"

else
    echo "Helm release $RELEASE_NAME not found. Skipping."
fi


# --------------------------------------------------
# 2. PostgreSQL database
# --------------------------------------------------

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

echo "PostgreSQL container: $DB_CONTAINER"


# Закрываем активные подключения к БД стенда
docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${DB_NAME}'
      AND pid <> pg_backend_pid();
"


# Удаляем БД
docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    DROP DATABASE IF EXISTS ${DB_NAME};
"


# --------------------------------------------------
# 3. Redis
# --------------------------------------------------

echo
echo "3. Cleaning Redis DB..."

if [ -n "$REDIS_DB" ]; then

    REDIS_CONTAINER=$(docker ps -q \
      --filter "label=com.docker.compose.project=day1-stand" \
      --filter "label=com.docker.compose.service=redis" \
      | head -n 1)

    if [ -z "$REDIS_CONTAINER" ]; then
        echo "ERROR: Redis container not found"
        exit 1
    fi

    echo "Redis container: $REDIS_CONTAINER"
    echo "Flushing Redis DB $REDIS_DB..."

    docker exec "$REDIS_CONTAINER" \
      redis-cli -n "$REDIS_DB" FLUSHDB

else

    echo "Redis DB was not found in Helm values."
    echo "Skipping Redis cleanup."

fi


# --------------------------------------------------
# Done
# --------------------------------------------------

echo
echo "========================================"
echo "Stand deleted successfully"
echo
echo "Branch:   $BRANCH"
echo "Release:  $RELEASE_NAME"
echo "Database: $DB_NAME"
echo "Redis DB: ${REDIS_DB:-unknown}"
echo "========================================"