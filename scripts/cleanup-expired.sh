#!/bin/sh
set -e

NAMESPACE="stands"

echo "========================================"
echo "TTL cleanup started"
echo "Namespace: $NAMESPACE"
echo "========================================"

NOW=$(date +%s)

RELEASES=$(helm list -n "$NAMESPACE" -q)

if [ -z "$RELEASES" ]; then
    echo "No Helm releases found."
    exit 0
fi

for RELEASE in $RELEASES
do
    echo
    echo "Checking $RELEASE..."

    VALUES=$(helm get values "$RELEASE" \
        -n "$NAMESPACE" \
        -o yaml 2>/dev/null || true)

    TTL=$(echo "$VALUES" |
        awk -F': ' '$1 == "ttlHours" {gsub(/"/, "", $2); print $2}')

    BRANCH=$(echo "$VALUES" |
        awk -F': ' '$1 == "branch" {gsub(/"/, "", $2); print $2}')

    if [ -z "$TTL" ]; then
        echo "No ttlHours found. Skipping."
        continue
    fi

    if [ -z "$BRANCH" ]; then
        echo "No branch found. Skipping."
        continue
    fi

    CREATED=$(kubectl get deployment "$RELEASE" \
        -n "$NAMESPACE" \
        -o jsonpath='{.metadata.creationTimestamp}' \
        2>/dev/null || true)

    if [ -z "$CREATED" ]; then
        echo "Deployment not found. Skipping."
        continue
    fi

    CREATED_SECONDS=$(date -d "$CREATED" +%s)
    AGE_SECONDS=$((NOW - CREATED_SECONDS))
    TTL_SECONDS=$((TTL * 3600))

    AGE_HOURS=$((AGE_SECONDS / 3600))

    echo "Branch:      $BRANCH"
    echo "Created:     $CREATED"
    echo "Age:         ${AGE_HOURS}h"
    echo "TTL:         ${TTL}h"

    if [ "$AGE_SECONDS" -ge "$TTL_SECONDS" ]; then

        echo "EXPIRED: $RELEASE"
        echo "Deleting..."

        sh ./scripts/delete-stand.sh "$BRANCH"

    else
        REMAINING=$(((TTL_SECONDS - AGE_SECONDS) / 3600))

        echo "Active. Approximately ${REMAINING}h remaining."
    fi
done

echo
echo "========================================"
echo "TTL cleanup finished"
echo "========================================"