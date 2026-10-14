#!/bin/sh
set -e

NAMESPACE="stands"
RELEASE_NAME="$1"

if [ -z "$RELEASE_NAME" ]; then
    echo "Usage: allocate-redis.sh <release-name>" >&2
    exit 1
fi

# Если этот стенд уже существует — оставляем ему тот же Redis DB
if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    EXISTING=$(helm get values "$RELEASE_NAME" \
        -n "$NAMESPACE" \
        -o json 2>/dev/null \
        | sed -n 's/.*"redis":{[^}]*"database":\([0-9][0-9]*\).*/\1/p')

    if [ -n "$EXISTING" ]; then
        echo "$EXISTING"
        exit 0
    fi
fi

USED=""

for RELEASE in $(helm list -n "$NAMESPACE" -q)
do
    DB=$(helm get values "$RELEASE" \
        -n "$NAMESPACE" \
        -o json 2>/dev/null \
        | sed -n 's/.*"redis":{[^}]*"database":\([0-9][0-9]*\).*/\1/p')

    if [ -n "$DB" ]; then
        USED="$USED $DB"
    fi
done

for DB in $(seq 1 15)
do
    if ! echo " $USED " | grep -q " $DB "; then
        echo "$DB"
        exit 0
    fi
done

echo "ERROR: No free Redis logical database available (1-15)" >&2
exit 1