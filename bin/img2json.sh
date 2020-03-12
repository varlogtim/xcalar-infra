#!/bin/bash

. infra-sh-lib

aws_ami2json(){
    aws ec2 describe-images --image-ids "$@" --query 'Images[].Tags[]' | \
        jq -r '{ami: map_values({(.Key): .Value})|add} * {ami: { ami_id: "'$1'"}}'
}


main() {
    local format=json
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
            --format=*) format="${cmd#--format=}";;
            --format) format="$1"; shift;;
            ami-*)
                if [ "$format" = cli ]; then
                    tmp=$(mktemp -t ami.XXXXXX.json)
                    if ! aws_ami2json "$cmd" > $tmp; then
                        die "Failed to query info for $cmd"
                    fi
                    args=(--version $(jq -r '.ami.Version' $tmp) --release $(jq -r '.ami.Build' $tmp)-$(jq -r .ami.ImageBuild $tmp))
                    echo "${args[@]}"
                    rm $tmp
                elif [ "$format" = json ]; then
                    aws_ami2json "$cmd"
                else
                    die "Unknown format: $format"
                fi
                ;;
            *) die "Unknown command: $cmd";;
        esac
    done
}


main "$@"
