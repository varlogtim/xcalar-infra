#!/bin/bash


if [ $# -eq 0 ]; then
    cd "$(git rev-parse --show-cdup)"
	SCRIPTS=()
	for FILE in $(git diff --diff-filter=AM --stat --name-only HEAD^); do
		if file "$FILE" | grep -q 'shell script'; then
			SCRIPTS+=($FILE)
		fi
	done
	if [ ${#SCRIPTS[@]} -gt 0 ]; then
		set -- "${SCRIPTS[@]}"
	fi
fi


if [ $# -eq 0 ]; then
	echo "No files specified"
	exit 0
fi

if [ -n "$SHELLCHECK_EXCLUDES" ]; then
    SHELLCHECK_EXCLUDES="SC2086,${SHELLCHECK_EXCLUDES}"
else
    SHELLCHECK_EXCLUDES="SC2086"
fi

docker run -v "${PWD}:${PWD}:ro" -w "$PWD" --rm koalaman/shellcheck -e ${SHELLCHECK_EXCLUDES} -x -s bash --color=always "$@"
