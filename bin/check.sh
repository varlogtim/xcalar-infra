#!/bin/bash

DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
rc=0
for FILE in "$@"; do
    desc="$(file $FILE)"
    if [[ "$desc" =~ "shell script" ]]; then
        echo >&2 "Checking $FILE ..."
        if ! shellcheck -S info "$FILE"; then
            $DIR/shellcheck.sh "$FILE" || rc=1
        fi
    elif echo "$FILE" | grep -q '\.json$'; then
        echo >&2 "Checking $FILE ..."
        jq -r . "$FILE" >/dev/null || rc=1
    fi
done
exit $rc
