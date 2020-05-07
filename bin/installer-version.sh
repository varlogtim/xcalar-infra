#!/bin/bash
#
# shellcheck disable=SC2086,SC2207

. infra-sh-lib

JSON=$(mktemp -t img-XXXXXX.json)

aws_ami2json(){
    aws ec2 describe-images --image-ids "$@" --query 'Images[].Tags[]' | \
        jq -r '{ami: map_values({(.Key): .Value})|add} * {ami: { ami_id: "'$1'"}}'
}

# jq -r '.Parameters|to_entries|map_values({UsePreviousValue: false, ParameterKey: .key, ParameterValue: .value.Default})'
# jq -r "to_entries|map(\"export \(.key)=\(.value|tostring)\")|.[]"

json_field() {
    local res
    res="$(jq -r "$1" < "$JSON" 2>/dev/null)"
    if [ "$res" = null ]; then
        return 1
    fi
    echo "$res"
    return 0
}

yaml2() {
    case "$1" in
        yml|yaml) sed '/^$/d';;
        *) cfn-flip;;
    esac
}

transform() {
    cat <<-EOF | yaml2 $FORMAT > $JSON
	${installer:+installer: "'$installer'"}
	${installer_url:+installer_url: "'$installer_url'"}
	${installer_version:+installer_version: "'$installer_version'"}
	${installer_build_number:+installer_build_number: "'$installer_build_number'"}
	${installer_build_type:+installer_build_type: $installer_build_type}
	${installer_rc:+installer_rc: "'$installer_rc'"}
	${installer_xce_branch:+installer_xce_branch: "'$installer_xce_branch'"}
	${installer_xce_sha1:+installer_xce_sha1: "'$installer_xce_sha1'"}
	${installer_xd_branch:+installer_xd_branch: "'$installer_xd_branch'"}
	${installer_xd_sha1:+installer_xd_sha1: "'$installer_xd_sha1'"}
	${image_build_number:+image_build_number: "'$image_build_number'"}
	${release:+release: $release}
	${product:+product: $product}
	${installer_tag:+installer_tag: "'$installer_tag'"}
	EOF
    case "$FORMAT" in
        yaml|yml) cat "$JSON";;
        json) cat "$JSON";;
        cli) jq -r "to_entries|map(\"--\(.key) \(.value|tostring)\")|.[]" $JSON;;
        vars) jq -r "to_entries|map(\"--var \(.key)=\(.value|tostring)\")|.[]" $JSON;;
        sh) jq -r "to_entries|map(\"\(.key|ascii_upcase)=\(.value|tostring)\")|.[]" $JSON;;
        *) echo >&2 "ERROR: $0: Unknown format $FORMAT"; return 2;;
    esac
    return $?
}

check_build_meta() {
    if [[ "$1" =~ /prod/ ]]; then
        installer_build_type=prod
    elif [[ "$1" =~ /debug/ ]]; then
        installer_build_type=debug
    fi
    if [[ "$1" =~ RC([0-9]+) ]]; then
        installer_rc="${BASH_REMATCH[1]}"
    fi
    local full_link
    if full_link=$(readlink -f "$installer"); then
        full_dir="$(dirname $full_link)"
        sha_info="${full_dir}/../BUILD_SHA"
        if test -e "${sha_info}"; then
            XCE=($(head -1 "$sha_info" | awk '{print $1 $2 $3}' | tr '():' ' '))
            XD=($(tail -1 "$sha_info" | awk '{print $1 $2 $3}' | tr '():' ' '))
            installer_xce_branch=${XCE[1]}
            installer_xce_sha1=${XCE[2]}
            installer_xd_branch=${XD[1]}
            installer_xd_sha1=${XD[2]}
        fi
    fi
}

usage() {
    cat <<-EOF
    usage: $0 [--format=(json|yml|sh)] [--image_build_number=#] ami-id or \
            /path/to/installeraaa or directly use S3
	EOF
}

main() {
    FORMAT=json
    ARGS=()
    while [ $# -gt 0 ]; do
        local cmd="$1"
        shift
        case "$cmd" in
            -h|--help) usage; exit 0;;
            --format=*) FORMAT="${cmd#--format=}";;
            --format) FORMAT="$1"; shift;;
            --image_build_number=*) image_build_number="${cmd#--image_build_number=}";;
            --image_build_number) image_build_number="$1"; shift;;
            -*) die "Unknown command: $cmd";;
            ami-*)
                AMI_ID="$cmd"
                ARGS+=("$AMI_ID")
                if ! aws_ami2json "$AMI_ID" > $JSON; then
                    die "Failed to query info for $AMI_ID"
                fi
                installer_version=$(json_field '.ami.Version')
                installer_rc=$(json_field '.ami.RC')
                installer_build_number=$(json_field '.ami.Build')
                image_build_number=$(json_field '.ami.ImageBuild')
                release=$(json_field '.ami.Release')
                product=$(json_field '.ami.Product')
                ;;
            /*|s3*|http*)
                if [[ "$cmd" =~ ^(http|s3) ]]; then
                    installer_url="$cmd"
                    ARGS+=("$installer_url")
                    parsed_installer="${cmd%%\?*}"
                    parsed_installer="${parsed_installer#*:/}"
                    check_build_meta "$parsed_installer"
                    vbi=($(version_build_from_filename "$parsed_installer"))
                elif [[ "$cmd" =~ ^/ ]] || [ -e "$cmd" ]; then
                    installer="$cmd"
                    check_build_meta "$installer"
                    if readlink "$installer" >/dev/null 2>&1; then
                        check_build_meta "$(readlink "$installer")"
                    fi
                    if readlink -f "$installer" >/dev/null 2>&1; then
                        installer="$(readlink -f "$installer")"
                        check_build_meta "$installer"
                    fi
                    ARGS+=("$installer")
                    vbi=($(version_build_from_filename "$installer"))
                fi
                installer_version=${vbi[0]}
                installer_build_number=${vbi[1]}
                ;;
            *) die "Unknown command: $cmd";;
        esac
    done
    if [ -n "$installer_rc" ]; then
        installer_tag="${installer_version:+$installer_version}${installer_rc:+-RC${installer_rc}}${release:+-$release}"
    else
        installer_tag="${installer_version:+$installer_version}${installer_build_number:+-$installer_build_number}${image_build_number:+-$image_build_number}${release:+-$release}"
    fi
    if [ -z "$installer_tag" ] || [ ${#ARGS[@]} -eq 0 ]; then
        die "Must specify a valid installer path/url to parse"
    fi
    transform
}


if ! main "$@"; then
    echo "AMI: $AMI_ID"
    cat $JSON >&2
    exit 1
fi
rm -f "$JSON"
exit 0
