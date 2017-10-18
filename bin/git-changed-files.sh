#!/bin/bash
if [ $# -eq 0 ]; then
    set -- $GIT_PREVIOUS_COMMIT ${GIT_COMMIT}
fi
git diff --name-only "$@"
