#!/bin/bash

aws_meta() {
    curl --connect-timeout=2 --fail --silent http://169.254.169.254/2018-09-24/meta-data/"$1"
}

discover() {
    local key="$1"
    local bucket
    if [[ $key =~ ^s3:// ]]; then
        key="${key#s3://}"
        bucket="${key%%/*}"
        key="${key#${bucket}/}"
    elif [[ $key =~ ^/ ]]; then
        bucket="${key#/}"
        bucket="${bucket%%/*}"
        key="${key#/${bucket}/}"
    else
        bucket="${BUCKET}"
    fi

    aws kinesisanalytics discover-input-schema \
        --s3-configuration RoleARN=${KINESISROLEARN},BucketARN=arn:aws:s3:::${bucket},FileKey="$key"
}

strjoin() {
    local IFS="$1"
    shift
    echo "$*"
}

main() {
    if [ -z "$AWS_DEFAULT_REGION" ]; then
        if AVZONE=$(aws_meta placement/availability-zone); then
            export AWS_DEFAULT_REGION="${AVZONE%[a-i]}"
        else
            export AWS_DEFAULT_REGION="us-west-2"
        fi
    fi

    local filter=()
    [ -n "$BUCKET" ] && filter+=('BUCKET')
    [ -n "$KINESISROLEARN" ] && filter+=('KINESISROLEARN')
    grepFilter="(\"\$(strjoin '|' \"${filter[*]}\")\")"

    if test -r /var/lib/cloud/instance/ec2.env; then
        set -a
        . /var/lib/cloud/instance/ec2.env
        set +a
    fi

    while [ $# -gt 0 ]; do
        cmd="$1"
        case "$cmd" in
            -b | --bucket)
                BUCKET="$2"
                shift 2
                ;;
            -r | --role)
                KINESISROLEARN="$2"
                shift 2
                ;;
            *) break ;;
        esac
    done

    BUCKET=${BUCKET:-xcfield}
    KISESISROLEARN="${KINESISROLEARN:-arn:aws:iam::559166403383:role/abakshi-instamart-KinesisServiceRole-K6TURBTVX2EF}"
    for ii in "$@"; do
        discover "$ii"
    done
}

main "$@"
