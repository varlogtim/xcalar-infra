#!/bin/bash
#
#
# shellcheck disable=SC2086,SC2207,SC1091

. infra-sh-lib

JSON=$(mktemp -t installer-version-XXXXXX.json)
DEFAULT_REGISTRY="${DEFAULT_REGISTRY:-registry.int.xcalar.com}"

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
	${installer_byjob:+installer_byjob: "$installer_byjob"}
	${docker_image:+docker_image: "'$docker_image'"}
	${release:+release: $release}
	${product:+product: $product}
	${license:+license: "'$license'"}
	${image_id:+image_id: "'$image_id'"}
	${LICENSE_TYPE:+license_type: "'$LICENSE_TYPE'"}
	${installer_tag:+installer_tag: "'$installer_tag'"}
	EOF
    case "$FORMAT" in
        yaml|yml) cat "$JSON";;
        json) cat "$JSON";;
        cli) jq -r "to_entries|map(\"--\(.key) \(.value|tostring)\")|.[]" $JSON;;
        clieq) jq -r "to_entries|map(\"--\(.key)=\(.value|tostring)\")|.[]" $JSON;;
        hcvar) jq -r "to_entries|map(\"-var \(.key)=\(.value|tostring)\")|.[]" $JSON;;
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
    if ! full_link="$(readlink -f "$1")"; then
        full_link="$1"
    fi
    vbi=($(version_build_from_filename "$full_link"))
    installer_version=${vbi[0]}
    installer_build_number=${vbi[1]}
    full_dir="$(dirname "$full_link")"
    sha_info="${full_dir}"/../BUILD_SHA
    installer_byjob="$(grep -Eow 'byJob/([A-Za-z0-9_-]+)' <<< $full_link | sed -r 's@byJob/@@')"
    if test -e "${sha_info}"; then
        XCE=($(head -1 "$sha_info" | awk '{print $1 $2 $3}' | tr '():' ' '))
        XD=($(tail -1 "$sha_info" | awk '{print $1 $2 $3}' | tr '():' ' '))
        installer_xce_branch=${XCE[1]}
        installer_xce_sha1=${XCE[2]}
        installer_xd_branch=${XD[1]}
        installer_xd_sha1=${XD[2]}
        if [ -z "$installer_rc" ]; then
            if [[ "$installer_xce_branch" =~ RC([0-9]+) ]]; then
                installer_rc="${BASH_REMATCH[1]}"
            elif [[ "$installer_xd_branch" =~ RC([0-9]+) ]]; then
                installer_rc="${BASH_REMATCH[1]}"
            fi
        fi
    fi
}

usage() {
    cat <<-EOF
    usage: $0 [--format=(cli|clieq|vars|hcvar|json|yml|sh)] [--image_build_number=#] ami-id or \
            /path/to/installer or directly use S3
	EOF
}

vaultv1() {
    [ $# -gt 0 ] || set -- /auth/token/lookup-self
    local rc=9 http_code tmpf
    tmpf=$(mktemp -t vault.XXXXXX)
    if http_code=$(curl -s -L -H "X-Vault-Request: true" -H "X-Vault-Token: $(vault print token)" "${VAULT_ADDR:-https://vault.service.consul:8200}"/v1/"${1#/}" -w '%{http_code}\n' -o "$tmpf"); then
        case "$http_code" in
            20*) cat "$tmpf"
                 rc=0
                 ;;
            400) rc=2;;
            403) rc=3;;
            40*) rc=4;;
            *) rc=5;;
        esac
    fi
    if [ $rc -eq 0 ]; then
        cat "$tmpf"
    fi
    rm -f "$tmpf"
    return $rc
}

load_license() {
    local license_type="$1"
    if ! vaultv1 >/dev/null; then
        return 1
    fi
    local license
    if license=$(vault kv get -format=json -field=data secret/xcalar_licenses/cloud 2>/dev/null | jq -r ".${license_type}" 2>/dev/null); then
        if [ "$license" != null ]; then
            echo "$license"
            return 0
        fi
    fi
    return 1
}

main() {
    FORMAT=json
    ARGS=()
    while [ $# -gt 0 ]; do
        local cmd="$1" maybe_installer
        shift
        case "$cmd" in
            -h|--help) usage; return 0;;
            --format=*) FORMAT="${cmd#--format=}";;
            --format) FORMAT="$1"; shift;;
            --license) LICENSE="$1"; shift;;
            --license-file) LICENSE="$(cat "$1")"; shift;;
            --license-type) LICENSE_TYPE="$1"; shift;;
            --image_build_number=*) image_build_number="${cmd#--image_build_number=}";;
            --image_build_number) image_build_number="$1"; shift;;
            -*) die "Unknown command: $cmd";;
            ami-*)
                AMI_ID="$cmd"
                ARGS+=("$AMI_ID")
                if ! aws_ami2json "$AMI_ID" > $JSON; then
                    die "Failed to query info for $AMI_ID"
                fi
                image_id=$AMI_ID
                installer_version=$(json_field '.ami.Version')
                installer_rc=$(json_field '.ami.RC')
                installer_build_number=$(json_field '.ami.Build')
                image_build_number=$(json_field '.ami.ImageBuild')
                release=$(json_field '.ami.Release')
                product=$(json_field '.ami.Product')
                for maybe_installer in /netstore/builds/byJob/Build{Trunk,Custom}/${installer_build_number}/prod/xcalar-${installer_version}-${installer_build_number}-installer; do
                    if test -e "$maybe_installer"; then
                        installer="$maybe_installer"
                        check_build_meta "$installer"
                    fi
                done
                ;;
            /*|s3*|http*)
                if [[ $cmd =~ ^(http|s3) ]]; then
                    installer_url="$cmd"
                    ARGS+=("$installer_url")
                    parsed_installer="${cmd%%\?*}"
                    parsed_installer="${parsed_installer#*:/}"
                    check_build_meta "$parsed_installer"
                elif [[ $cmd =~ ^/ ]] || [ -e "$cmd" ]; then
                    installer="$cmd"
                    check_build_meta "$installer"
                    ARGS+=("$installer")
                fi
                ;;
            *) die "Unknown command: $cmd";;
        esac
    done
    if [ -z "$LICENSE_DATA" ]; then
        for ii in license.json license-dev.json license-rc.json; do
            if test -e $ii; then
                LICENSE_DATA="$ii"
                break
            fi
        done
    fi
    if [ -z "${LICENSE_TYPE}" ]; then
        if [ -n "$installer_rc" ]; then
            LICENSE_TYPE=rc
        else
            LICENSE_TYPE=dev
        fi
    fi

    if [ -n "$LICENSE" ]; then
        license="$LICENSE"
    elif [ -e "$LICENSE_DATA" ]; then
        license="$(jq -r .license.${LICENSE_TYPE} < "$LICENSE_DATA" 2>/dev/null)"
    else
        license="$(load_license $LICENSE_TYPE 2>/dev/null)"
    fi

    if [ -n "$installer_rc" ]; then
        installer_tag="${installer_version:+$installer_version}${installer_build_number:+-$installer_build_number}${image_build_number:+-$image_build_number}${installer_rc:+-RC${installer_rc}}${release:+-$release}"
    else
        installer_tag="${installer_version:+$installer_version}${installer_build_number:+-$installer_build_number}${image_build_number:+-$image_build_number}${release:+-$release}"
    fi
    if [ -z "$installer_tag" ] || [ ${#ARGS[@]} -eq 0 ]; then
        die "Must specify a valid installer path/url to parse"
    fi
    docker_image="$(registry_repo_mf "${REPO:-xcalar/xcalar}" "$installer_tag")"
    transform
}

ok_or_not() {
    local name="$1"
    shift
    if eval "$@"; then
        echo "ok $test_idx - $name" '(' "$@" ')'
        ok=$(( ok + 1 ))
    else
        echo "not ok $test_idx - $name" '(' "$@" ')'
        not_ok=$(( not_ok + 1 ))
    fi
    test_idx=$((test_idx+1))
}

SHA1CHECK=$(sed '/^SHA1CHECK/d' "${BASH_SOURCE[0]}" | sha1sum | cut -d' ' -f1)
SHA1CHECK_OK=9f80a5e55c917fa12844a89660d33ea548f446b1
# shellcheck disable=SC2016,SC2046,SC2034
if [ -z "$IN_TEST" ] && ( [ "$1" = --test ] || [ "$SHA1CHECK" != "$SHA1CHECK_OK" ] ); then
    export IN_TEST=1
    (
    echo "TAP 1.3"
    echo "1..12"
    test_idx=1 not_ok=0 ok=0
    eval $(bash "${BASH_SOURCE[0]}" --format=sh /netstore/builds/byJob/BuildTrunk/4305/prod/xcalar-2.3.0-4305-installer)
    rc=$?
    ok_or_not '4305-is-loaded' test "\$rc" = 0
    ok_or_not '4305-is-rc6' test "\$INSTALLER_TAG" = '2.3.0-4305-RC6'
    ok_or_not '4305-docker-image' test "\$DOCKER_IMAGE" = "registry.int.xcalar.com/xcalar/xcalar:2.3.0-4305-RC6"
    ok_or_not '4305-license-type' test "\$LICENSE_TYPE" = "rc"
    ok_or_not '4305-xce-sha1' test "\$INSTALLER_XCE_SHA1" = '659b139b'
    eval $(bash "${BASH_SOURCE[0]}" --format=sh /netstore/builds/byJob/BuildTrunk/4307/prod/xcalar-2.3.0-4307-installer)
    rc=$?
    ok_or_not '4307-is-loaded' test '$rc' = 0
    ok_or_not '4307-is-not-rc' test '$INSTALLER_TAG' = '2.3.0-4307'
    ok_or_not '4307-docker-image' test '$DOCKER_IMAGE' = "registry.int.xcalar.com/xcalar/xcalar:2.3.0-4307"
    ok_or_not '4307-license-type' test '$LICENSE_TYPE' = "dev"
    ok_or_not '4307-xd-sha1' test '$INSTALLER_XD_SHA1' = '9e187765'

    json_obj=$(installer-version.sh /netstore/builds/byJob/BuildTrunk/4309/prod/xcalar-2.3.0-4309-installer | jq -c -r '{installer_tag,docker_image,installer_build_type,installer_xd_sha1}')
    rc=$?
    ok_or_not '4309-is-loaded' test '$rc' = 0
    ok_or_not '4309-json-check' test '"$json_obj"' = '"{\"installer_tag\":\"2.3.0-4309\",\"docker_image\":\"registry.int.xcalar.com/xcalar/xcalar:2.3.0-4309\",\"installer_build_type\":\"prod\",\"installer_xd_sha1\":\"97f2e1a0\"}"'
    if [ "$not_ok" -gt 0 ] || [  "$ok" -ne 12 ]; then
        die "Test failed ok=$ok , not_ok=$not_ok"
    fi
    )>&2
    sed -r -i 's/^SHA1CHECK_OK=.*$/SHA1CHECK_OK='$SHA1CHECK'/' "${BASH_SOURCE[0]}"
    [ "$1" = --test ] && exit 0
    exec bash "${BASH_SOURCE[0]}" "$@"
fi

if ! main "$@"; then
    cat $JSON >&2
    exit 1
fi
rm -f "$JSON"
exit 0
