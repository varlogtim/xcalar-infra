#!/bin/bash

NUM_INSTANCES=1
PARAMETERS="${PARAMETERS:-parameters.json}"

if [ "$1" == -h ] || [ "$1" == --help ]; then
    echo >&2 "usage: $0 [<license.txt or long-license-string> default: parse $PARAMETERS] [<number of instances>: default $NUM_INSTANCES]"
    exit 1
fi

if test -n "$1"; then
    if test -f "$1"; then
        LICENSE="$(cat "$1")"
    else
        LICENSE="$1"
    fi
    shift
else
    if ! test -f $PARAMETERS; then
        echo >&2 "ERROR: $PARAMETERS is missing and neither license file nor license was specified!"
        exit 1
    fi
    if ! LICENSE="$(jq -r .parameters.licenseKey.value $PARAMETERS 2>/dev/null || jq -r .licenseKey.value $PARAMETERS 2>/dev/null)"; then
        echo >&2 "ERROR: Unable to parse licenseKey from $PARAMETERS"
        exit 1
    fi
fi
if test -n "$1"; then
    NUM_INSTANCES="$1"
    shift
fi

curl -4 --location --retry 20 --retry-delay 3 --retry-max-time 60 \
		-sH 'Content-Type: application/json' -X POST \
		-d '{ "licenseKey": "'$LICENSE'", "numNodes": '$NUM_INSTANCES', "installerVersion": "latest" }' \
		https://zqdkg79rbi.execute-api.us-west-2.amazonaws.com/stable/installer | jq -r .
