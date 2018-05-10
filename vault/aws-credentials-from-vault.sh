#!/bin/bash
# <-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------``````````````````````````````````````````````````````````````
## Vault gives us this format
#{
#  "request_id": "9f8f7133-e341-5cfb-437f-f98646bf8d0f",
#  "lease_id": "aws/sts/deploy/d177f27b-9251-d261-956d-66b59428e79c",
#  "lease_duration": 3599,
#  "renewable": false,
#  "data": {
#    "access_key": "ASIAJEGZPHIMPZHJHIMQ",
#    "secret_key": "6chW+auMR53SFjrlhknxQohogp5xe7BFYuC8Kk23",
#    "security_token": "FQoDYXdzENj//////////wEaDNSxT0hN2kESqT1U/iL6AVrZFwmD0VWbNui+salnSrEuNTeVKwQacSzlQmlg4uCpuMSmhZb81GRn1mbkAE7iT/nr7TRJUoHBC75mMovLfjWBTNGfFSv8+Vq4plbHbKbigKznucSic+9o/TmzvxUtjvjEmHqYOQWPbvix6krSWVxbinL29AVpgV4A6hUro0FuGaQNGfjAPrb3D0xYgDt2UXV65v0ufiRcS0Ql4o8Rtepx9p8QUIZnMcbVlYWO+//Fh1A/SqBJQIMWIppZrtwHfjnNHqlqQLGI3Nz6rPCttTbhaZ7FJMW6TJ3jWrsQXCo68zdarVeDsjjVeTqsppr7jOpBzMT2+Ment9EopP6t1gU="
#  },
#  "warnings": null
#}
## Aws wants this (via https://docs.aws.amazon.com/cli/latest/topic/config-vars.html#sourcing-credentials-from-external-processes)
#{
#  "Version": 1,
#  "AccessKeyId": "",
#  "SecretAccessKey": "",
#  "SessionToken": "",
#  "Expiration": ""
#}


AWSPATH="aws-xcalar/sts/xcalar-test-poweruser"

while [ $# -gt 0 ]; do
    cmd="$1"
    case "$cmd" in
        -f|--file) FILE="$2";shift 2;;
        --path) AWSPATH="$2"; shift 2;;
        --export) EXPORT=1; shift;;
        --) shift; break;;
        -*) echo >&2 "ERROR: Unknown argument $cmd"; exit 1;;
        *) break;;
    esac
done

TMP="$(mktemp /tmp/vault.XXXXX)"
if [ "$FILE" = - ]; then
    FILE="$(mktemp /tmp/vault.XXXXXX)"
    trap "rm -f $FILE" EXIT
    cat - > $FILE
elif [ -r "$1" ]; then
    FILE="$1"
else
    FILE="$(mktemp /tmp/vault.XXXXXX)"
    trap "rm -f $FILE" EXIT
    case "$AWSPATH" in
        aws/sts/*) vault write -format=json "$AWSPATH" "$@" > "$FILE";;
        aws/creds/*) vault read -format=json $AWSPATH "$@" > "$FILE";;
        *) echo >&2 "ERROR: Unknown type of path $AWSPATH"; exit 2;;
    esac
fi

SECONDS="$(jq -r .lease_duration "$FILE")"
EXPIRATION="$(date -u -d "$SECONDS seconds" +%FT%T.000Z)"

if [ "$EXPORT" = 1 ]; then
    echo export AWS_ACCESS_KEY_ID=$(jq -r .data.access_key $FILE)
    echo export AWS_SECRET_ACCESS_KEY=$(jq -r .data.secret_key $FILE)
    echo export AWS_SESSION_TOKEN=$(jq -r .data.security_token $FILE)
else
    jq '
    {
        Version: 1,
        AccessKeyId: .data.access_key,
        SecretAccessKey: .data.secret_key,
        SessionToken: .data.security_token,
        Expiration:"'$EXPIRATION'"
    }' < "$FILE"
fi



