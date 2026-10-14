#!/bin/sh
set -e

NAMESPACE="stands"
REPOSITORY="https://github.com/abilgazinaadina/creatio-packages.git"

echo "========================================"
echo "Deleted branch cleanup"
echo "========================================"

REMOTE_BRANCHES=$(git ls-remote --heads "$REPOSITORY" \
    | sed 's#.*refs/heads/##')

echo
echo "Existing Git branches:"
echo "$REMOTE_BRANCHES"
echo


for RELEASE in $(helm list -n "$NAMESPACE" -q)
do

    echo "----------------------------------------"
    echo "Checking release: $RELEASE"

    BRANCH=$(helm get values "$RELEASE" \
        -n "$NAMESPACE" \
        -o json 2>/dev/null \
        | sed -n 's/.*"branch":"\([^"]*\)".*/\1/p')

    if [ -z "$BRANCH" ]; then
        echo "No branch value found."
        echo "Skipping $RELEASE."
        continue
    fi

    echo "Branch: $BRANCH"


    if echo "$REMOTE_BRANCHES" | grep -Fxq "$BRANCH"; then

        echo "Branch still exists."
        echo "Stand will stay."

    else

        echo "Branch no longer exists."
        echo "Deleting stand..."

        sh ./scripts/delete-stand.sh "$BRANCH"

    fi

done


echo
echo "========================================"
echo "Deleted branch cleanup finished"
echo "========================================"