#!/bin/bash

dns_diff () {
    diff <(sort -u <(dig +nottlid +noall +answer @$2 $1 ANY) ) <(sort -u <(dig +nottlid +noall +answer @$3 $1 ANY) )
}

if [ $# -lt 3 ]; then
    echo >&2 "Usage: $0 example.com ns1.dnsprovider1.com ns1.dnsprovider2.com"
    echo >&2 "  Disaplay differences between records of two DNS providers"
    exit 1
fi
dns_diff "$@"
