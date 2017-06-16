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
        say "usage: $0 <path/to/installer>"
        say " upload the installer to repo.xcalar.net and print out new http url"
        exit 1
        ;;
    -*)
        say "ERROR: Unknown option $1"
        exit 1
        ;;
    *)
        INSTALLER="$1"
        shift
        ;;
esac


if test -f "$INSTALLER"; then
    INSTALLER="$(readlink_f "${INSTALLER}")"
    INSTALLER_FNAME="$(basename $INSTALLER)"
    if [[ "$INSTALLER" =~ '/debug/' ]]; then
        INSTALLER_URL="repo.xcalar.net/builds/debug/$INSTALLER_FNAME"
    elif [[ "$INSTALLER" =~ '/prod/' ]]; then
        INSTALLER_URL="repo.xcalar.net/builds/prod/$INSTALLER_FNAME"
    else
        INSTALLER_URL="repo.xcalar.net/builds/$INSTALLER_FNAME"
    fi
    if ! check_url "http://${INSTALLER_URL}"; then
        say "Uploading $INSTALLER to gs://$INSTALLER_URL"
        until gsutil -m -o GSUtil:parallel_composite_upload_threshold=100M -q \
                      cp -c "$INSTALLER" gs://$INSTALLER_URL; do
            sleep 1
        done
    else
        say "http://$INSTALLER_URL already exists. Not uploading."
    fi
    echo http://${INSTALLER_URL}
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
