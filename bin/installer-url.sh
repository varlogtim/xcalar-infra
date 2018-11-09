#!/bin/bash
#
# Copies an installer to S3/GCS, then provides a signed
# URL with $EXPIRY seconds validity.

. infra-sh-lib
. aws-sh-lib

# Links expire in 1 week by default. That's the max setting.
UPLOAD="gs,az"

if [ "$(uname -s)" = Darwin ]; then
    readlink_f() {
        (
            target="$1"

            cd "$(dirname $target)"
            target="$(basename $target)"

            # Iterate down a (possible) chain of symlinks
            while [ -L "$target" ]; do
                target="$(readlink $target)"
                cd "$(dirname $target)"
                target="$(basename $target)"
            done

            echo "$(pwd -P)/$target"
        )
    }
else
    readlink_f() {
        readlink -f "$@"
    }
fi

say() {
    echo >&2 "$*"
}

check_url() {
    curl -r 0-255 -fsL -o /dev/null "$1" -w '%{http_code}' | grep -q '^20'
}

az_blob() {
    local cmd="$1"
    shift
    az storage blob $cmd --account-name "$ACCOUNT" --container-name "$CONTAINER" --name "$BLOB" "$@"
}

if [ $# -eq 0 ]; then
    set -- -h
fi

while [ $# -gt 0 ]; do
    cmd="$1"
    case "$cmd" in
    -h | --help)
        say "Usage: $0 [-d <az|gs|s3>] [-e expiry-in-seconds (default 1w or 4w depending on cloud)] <path/to/installer>"
        say " upload the installer to repo.xcalar.net and print out new http url"
        exit 1
        ;;
    -e | --expiry | --expires-in)
        EXPIRY="$2"
        shift 2
        ;;
    --use-sha1)
        USE_SHA1=1
        shift
        ;;
    -d | --dest)
        DEST="$2"
        shift 2
        ;;
    -*)
        say "ERROR: Unknown option $1"
        exit 1
        ;;
    --)
        shift
        break
        ;;
    *) break ;;
    esac
done

INSTALLER="$1"

if test -f "$INSTALLER"; then
    INSTALLER="$(readlink_f "${INSTALLER}")"
    BUILD_SHA="$(dirname ${INSTALLER})/../BUILD_SHA"
    if test -f "$BUILD_SHA"; then
        SHAS=($(awk '{print $(NF)}' "${BUILD_SHA}" | tr -d '()'))
        SHA1="${SHAS[0]}-${SHAS[1]}"
    else
        SHA1="$(sha1sum $INSTALLER | awk '{print $1}')"
    fi
    INSTALLER_FNAME="$(basename $INSTALLER)"
    SUBDIR=$(basename $(dirname $INSTALLER))
    DEST_FNAME="${SUBDIR}/$INSTALLER_FNAME"
    test -n "$DEST" || DEST=s3

    case "$DEST" in
    gs)
        SA_URI="gs"
        SA_ACCOUNT="${SA_ACCOUNT:-repo.xcalar.net}"
        ;;
    s3)
        SA_URI="s3"
        case "$AWS_DEFAULT_REGION" in
            us-east-1) SA_ACCOUNT="${SA_ACCOUNT:-xcrepoe1}";;
            us-west-2) SA_ACCOUNT="${SA_ACCOUNT:-xcrepo}";;
        esac
        ;;
    az) SA_URI="az" ;;
    esac
    SA_ACCOUNT="${SA_ACCOUNT:-xcrepo}"
    SA_PREFIX="${SA_PREFIX:-builds}"
    DEST="${SA_URI}://${SA_ACCOUNT}/${SA_PREFIX}"
    if [ "$USE_SHA1" = 1 ]; then
        DEST_URL="${DEST}/${SHA1}/${DEST_FNAME}"
    else
        DEST_URL="${DEST}/${DEST_FNAME}"
    fi

    case "${DEST_URL}" in
    s3://*)
        export AWS_DEFAULT_REGION=$(aws_s3_region "$DEST_URL")
        EXPIRY=${EXPIRY:-604200}  # 1 week is max on AWS
        if [[ $EXPIRY -ge 604800 ]] || [[ $EXPIRY -le 0 ]]; then
            say "Invalid expiry. Must be one week or less"
            exit 1
        fi
        URL="$(aws s3 presign --expires-in $EXPIRY "$DEST_URL")"

        if ! check_url "$URL"; then
            say "Uploading $INSTALLER to $DEST_URL"
            aws s3 cp --metadata-directive REPLACE --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' --only-show-errors "$INSTALLER" "$DEST_URL" >&2
            # S3 eventual consistency at work
            sleep 5
        fi
        if [ $? -eq 0 ] && check_url "$URL"; then
            echo "$URL"
        else
            echo >&2 "Failed to verify $URL"
            exit 1
        fi
        ;;
    gs://*)
        if ! gsutil ls "$DEST_URL" > /dev/null 2>&1; then
            say "Uploading $INSTALLER to $DEST_URL"
            until gsutil -m -o GSUtil:parallel_composite_upload_threshold=100M -q \
                cp -c "$INSTALLER" "$DEST_URL" >&2; do
                sleep 1
            done
        fi
        echo https://storage.googleapis.com/"${DEST_URL#gs://}"
        ;;
    az://*)
        DEST_URL="${DEST_URL#az://}"
        ACCOUNT="${DEST_URL%%/*}"
        CONTAINER="${DEST_URL#*/}"
        CONTAINER="${CONTAINER%%/*}"
        BLOB=${DEST_URL#${ACCOUNT}/${CONTAINER}/}
        EXPIRY=${EXPIRY:-2419200}  # 4 weeks
        EXPIRES="$(date -d "$EXPIRY seconds" '+%Y-%m-%dT%H:%MZ')"
        URL="$(az_blob url -otsv)"
        CODE="$(az_blob generate-sas --permissions r --expiry $EXPIRES -otsv)"
        URL="${URL}?${CODE}"
        if ! check_url "$URL"; then
            az_blob upload -f "$INSTALLER" >&2
        fi
        if [ $? -eq 0 ] && check_url "$URL"; then
            echo "$URL"
            exit 0
        fi
        say "Failed to upload to $DEST_URL"
        exit 1
        ;;
    *)
        say "Unknown resource ${DEST_URL}"
        exit 1
        ;;
    esac
    exit 0
elif [[ ${INSTALLER} =~ ^http[s]?:// ]]; then
    if ! check_url "${INSTALLER}"; then
        say "Unable to access ${INSTALLER}"
        exit 1
    fi
    say "URL Verified OK"
    echo $INSTALLER
    exit 0
elif [[ ${INSTALLER} =~ ^s3:// ]]; then
    export AWS_DEFAULT_REGION=$(aws_s3_region "$INSTALLER")
    aws s3 presign --expires-in $EXPIRY "${INSTALLER}"
    exit $?
fi

say "Unable to locate $INSTALLER as either a valid file or URL"
exit 1
