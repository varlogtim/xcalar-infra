#!/bin/bash
#
# shellcheck disable=SC2207,SC2155

export XLRINFRADIR="$(cd "$(dirname ${BASH_SOURCE[0]})"/.. && pwd)"
export PATH=$XLRINFRADIR/bin:$PATH

FILES=($(git diff-tree --no-commit-id --name-only -r HEAD))
$XLRINFRADIR/bin/check.sh "${FILES[@]}"
