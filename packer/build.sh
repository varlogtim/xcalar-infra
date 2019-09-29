#!/bin/bash
#
# shellcheck disable=SC2086,SC1091

. infra-sh-lib
. aws-sh-lib

set -e

packer_do() {
    local cmd="$1"
    shift
    if [ -e $HOME/.packer-vars ]; then
        USER_VARS="$HOME/.packer-vars"
    fi
    $PACKER $cmd \
        -var "product=$PRODUCT" \
        -var "version=$INSTALLER_VERSION" \
        -var "build_number=$INSTALLER_BUILD_NUMBER" \
        -var "image_build_number=$IMAGE_BUILD_NUMBER" \
        -var "installer_url=$INSTALLER_URL" \
        ${REGIONS+-var "destination_regions=$REGIONS"} \
        ${SHARED_WITH+-var "shared_with=$SHARED_WITH"} \
        ${BUILD_URL+-var "build_url=$BUILD_URL"} \
        ${JOB_URL+-var "job_url=$JOB_URL"} \
        ${USER_VARS+-var-file $USER_VARS} \
        ${VAR_FILE+-var-file $VAR_FILE} "$@"
}

check_or_upload_installer() {
    if [ -z "$INSTALLER_URL" ]; then
        if [ -z "$INSTALLER" ]; then
            INSTALLER="$(latest-installer.sh)" || die "Failed to find latest installer"
        fi
        INSTALLER_URL="$(installer-url.sh -d s3 $INSTALLER)" || die "Failed to upload installer"
    fi

    if [[ "$INSTALLER_URL" =~ ^http ]]; then
        if URL_CODE=$(curl -f -s -o /dev/null -w '%{http_code}' -H "Range: bytes=0-500" -L "$INSTALLER_URL"); then
            if ! [[ $URL_CODE =~ ^2 ]]; then
                echo >&2 "InstallerURL failed! $INSTALLER_URL not found!"
                exit 1
            fi
        else
            echo >&2 "InstallerURL failed! $INSTALLER_URL not found!"
            exit 1
        fi
    elif [[ "$INSTALLER_URL" =~ ^s3:// ]]; then
        if ! aws_s3_head_object "$INSTALLER_URL" > /dev/null; then
            echo >&2 "InstallerURL failed! $INSTALLER_URL not found!"
            exit 1
        fi
    fi
}

main() {
    PROVIDER=aws
    SHARED_WITH="${SHARED_WITH-045297022527,043829555035,364047378361,876030232190}"
    REGIONS="${REGIONS-us-east-1,us-west-2}"

    while [ $# -gt 0 ]; do
        cmd="$1"
        case "$cmd" in
            --provider)
                PROVIDER="$2"
                shift 2
                ;;
            --osid)
                OSID="$2"
                shift 2
                ;;
            --shared-with)
                SHARED_WITH="$2"
                shift 2
                ;;
            --regions)
                REGIONS="$2"
                shift 2
                ;;
            --installer)
                INSTALLER="$2"
                shift 2
                ;;
            --installer-url)
                INSTALLER_URL="$2"
                shift 2
                ;;
            --template)
                TEMPLATE="$2"
                shift 2
                ;;
            --var-file)
                VAR_FILE="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            --*)
                echo >&2 "ERROR: Unknown parameter $cmd"
                exit 1
                ;;
            -*) break ;;
            *)
                if test -e "$1"; then
                    TEMPLATE="$1"
                    shift
                else
                    echo >&2 "ERROR: Don't understand $cmd ..."
                    exit 1
                fi
                ;;
        esac
    done

    download_packer || exit 1

    if [ -n "$TEMPLATE" ]; then
        if [[ $TEMPLATE =~ .yaml$ ]]; then
            JSON_TEMPLATE="${TEMPLATE%.yaml}".json
            cfn-flip < "$TEMPLATE" > "$JSON_TEMPLATE"
        fi
    fi

    if [ -z "$INSTALLER_URL" ]; then
        INSTALLER_URL="$(installer-url.sh -d s3 "$INSTALLER")"
    fi

    IMAGE_BUILD_NUMBER=${BUILD_NUMBER:-1}
    PRODUCT="${PRODUCT:-xdp-standard}"

    INSTALLER_VERSION_BUILD=($(version_build_from_filename "$(filename_from_url "$INSTALLER_URL")"))
    INSTALLER_VERSION="${INSTALLER_VERSION_BUILD[0]}"
    INSTALLER_BUILD_NUMBER="${INSTALLER_VERSION_BUILD[1]}"

    set +e
    if ! packer_do validate ${*/-color=*/} "$JSON_TEMPLATE" || ! packer_do build $* "$JSON_TEMPLATE"; then
        trap - EXIT
        echo "Failed! See $TMPDIR"
        exit 1
    fi
}

main "$@"
