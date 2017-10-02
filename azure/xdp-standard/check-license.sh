#!/bin/bash

if [ "$1" == -h ] || [ "$1" == --help ]; then
    echo >&2 "usage: $0 [license.txt or long-license-string] default: parse parameters.json"
    exit 1
fi

if test -n "$1"; then
    if test -f "$1"; then
        LICENSE="$(cat "$1")"
    else
        LICENSE="$1"
    fi
else
    if ! test -f parameters.json; then
        echo >&2 "ERROR: parameters.json is missing and neither license file nor license was specified!"
        exit 1
    fi
    LICENSE="$(jq -r .parameters.licenseKey.value parameters.json)"
fi

curl -4 --location --retry 20 --retry-delay 3 --retry-max-time 60 \
		-H 'Content-Type: application/json' -X POST \
		-d '{ "licenseKey": "'$LICENSE'", "numNodes": 3, "installerVersion": "latest" }' \
		https://zqdkg79rbi.execute-api.us-west-2.amazonaws.com/stable/installer | jq -r .
