#!/bin/bash

if [ "$(uname -s)" = Darwin ]; then
    readlink_f () {
        (
        target="$1"

        cd "$(dirname $target)"
        target="$(basename $target)"

        # Iterate down a (possible) chain of symlinks
        while [ -L "$target" ]
        do
            target="$(readlink $target)"
            cd "$(dirname $target)"
            target="$(basename $target)"
        done

        echo "$(pwd -P)/$target"
        )
    }
else
    readlink_f () {
        readlink -f "$@"
    }
fi

say () {
    echo >&2 "$*"
}

check_url () {
    curl -Is "$1" | head -n 1 | grep -q '200 OK'
}

if [ $# -eq 0 ]; then
    set -- -h
fi

case "$1" in
    -h|--help)
        say "usage: $0 [-d <gs|s3>] <path/to/installer>"
        say " upload the installer to repo.xcalar.net and print out new http url"
        exit 1
        ;;
    -d|--dest)
        DEST="$2"
        shift 2
        ;;
    -*)
        say "ERROR: Unknown option $1"
        exit 1
        ;;
esac
INSTALLER="$1"


if test -f "$INSTALLER"; then
    INSTALLER="$(readlink_f "${INSTALLER}")"
    BUILD_SHA="$(dirname ${INSTALLER})/../BUILD_SHA"
    if test -f "$BUILD_SHA"; then
        SHAS=($(awk '{print $(NF)}'  "${BUILD_SHA}" | tr -d '()'))
        SHA1="${SHAS[0]}-${SHAS[1]}"
    else
        SHA1="$(sha1sum $INSTALLER | awk '{print $1}')"
    fi
    INSTALLER_FNAME="$(basename $INSTALLER)"
    if [[ "$INSTALLER" =~ '/debug/' ]]; then
        DEST_FNAME="debug/$INSTALLER_FNAME"
    elif [[ "$INSTALLER" =~ '/prod/' ]]; then
        DEST_FNAME="prod/$INSTALLER_FNAME"
    else
        DEST_FNAME="$INSTALLER_FNAME"
    fi
    test -z "$DEST" && DEST=gs
    case "$DEST" in
        gs) DEST="gs://repo.xcalar.net/builds";;
        s3) DEST="s3://xcrepo/builds";;
    esac
    DEST_URL="${DEST}/${SHA1}/${DEST_FNAME}"
    case "${DEST_URL}" in
        s3://*)
            if ! aws s3 ls "$DEST_URL" &>/dev/null; then
                say "Uploading $INSTALLER to $DEST_URL"
                aws s3 cp --only-show-errors "$INSTALLER" "$DEST_URL"
            fi
            aws s3 presign --expires-in ${EXPIRY:-1800} "$DEST_URL"
            ;;
        gs://*)
            if ! gsutil ls "$DEST_URL"; then
                say "Uploading $INSTALLER to $DEST_URL"
                until gsutil -m -o GSUtil:parallel_composite_upload_threshold=100M -q \
                            cp -c "$INSTALLER" "$DEST_URL"; do
                    sleep 1
                done
            fi
            echo http://${INSTALLER_URL}
            ;;
        *)
            say "Unknown resource ${DEST_URL}"
            exit 1
            ;;
    esac
    exit 0
elif [[ "${INSTALLER}" =~ ^http[s]?:// ]]; then
    if ! check_url "${INSTALLER}"; then
        say "Unable to access ${INSTALLER}"
        exit 1
    fi
    echo $INSTALLER
    exit 0
fi

say "Unable to locate $INSTALLER as either a valid file or URL"
exit 1
