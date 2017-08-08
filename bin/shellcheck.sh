#!/bin/bash
#
# Shellcheck does static code analysis of shell scripts.
#
# Usage:
#   $ shellcheck.sh myscript.sh
#
set -e

if test $# -eq 1 && test -d "$1"; then
    DIR="$1"
    shift
    SCRIPTS=()
    for FILE in $(find "$DIR" -type f); do
        if file "$FILE" | grep -q 'shell script'; then
            SCRIPTS+=($FILE)
        fi
    done
    if [ ${#SCRIPTS[@]} -gt 0 ]; then
        set -- "${SCRIPTS[@]}"
    fi
fi

if test $# -eq 0; then
    echo >&2 "Usage: $0 [shellcheck options] script... or dir"
    exit 1
fi

if [ -n "$SHELLCHECK_EXCLUDES" ]; then
    SHELLCHECK_EXCLUDES="SC2086,${SHELLCHECK_EXCLUDES}"
else
    SHELLCHECK_EXCLUDES="SC2086"
fi

set +e
ERRORS=0
for FILE in "$@"; do
    docker run -v "${PWD}:${PWD}:ro" -w "$PWD" --rm koalaman/shellcheck -e ${SHELLCHECK_EXCLUDES} -x -s bash --color=always "$FILE"
    rc=$?
    if [ $rc != 0 ]; then
        echo "FAILED:($rc): $FILE"
        ERRORS=$(( ERRORS + 1 ))
    else
        echo "OK: ${FILE}"
    fi
done
if [ $ERRORS -gt 0 ]; then
    echo >&2 "ERROR: $ERRORS files failed"
    exit 1
fi
exit 0