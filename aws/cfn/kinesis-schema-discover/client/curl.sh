#!/bin/bash

API_ENDPOINT="${API_ENDPOINT:-https://qwps8i2l2g.execute-api.us-west-2.amazonaws.com/Prod/discover/}"

discover() {
    curl -Ls "${API_ENDPOINT}?bucket=$1&key=$(urlencode "$2")"
}

urlencode () {
    if [ $# -gt 0 ]; then
        printf '%s' "$1" | tr -d '\n' | jq -s -R -r '@uri'
    else
        tr -d '\n' | jq -s -R -r '@uri'
    fi
}

# Convert s3://bucket/path/to/my/key -> bucket path/to/my/key
bucket_and_key() {
    local bucket="${1#s3://}"
    if [ "$1" = "$bucket" ]; then
        echo >&2 "Invalid S3 Uri: $1"
        return 1
    fi
    bucket="${bucket%%/*}"
    local key="${1#s3://$bucket/}"
    echo "$bucket" "$key"
}

self_check() {
    local bucket='xcfield'
    local key='instantdatamart/csv/free-zipcode-database-Primary.csv'

    local test1=($(bucket_and_key "s3://${bucket}/${key}"))

    if [ "${test1[0]}" != "$bucket" ] || [ "${test1[1]}" != "$key" ]; then
        echo >&2 "Failed self check"
        exit 1
    fi
}

self_check

for arg in "$@"; do
    discover $(bucket_and_key "$arg")
done
