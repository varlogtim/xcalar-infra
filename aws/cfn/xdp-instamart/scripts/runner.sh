#!/bin/bash

set -e

# --- helper functions for logs ---
info() {
    log '[INFO] ' "$@"
}

fatal() {
    log '[ERROR] ' "$@" >&2
    exit 1
}

# --- log to syslog
log() {
    echo "$@" | logger --id=$$ -p local0.info -t runner -s
}

# --- add quotes to command arguments ---
quote() {
    for arg in "$@"; do
        printf '%s\n' "$arg" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"
    done
}

# --- add indentation and trailing slash to quoted args ---
quote_indent() {
    printf ' \\\n'
    for arg in "$@"; do
        printf '\t%s \\\n' "$(quote "$arg")"
    done
}

# --- escape most punctuation characters, except quotes, forward slash, and space ---
escape() {
    printf '%s' "$@" | sed -e 's/\([][!#$%&()*;<=>?\_`{|}]\)/\\\1/g;'
}

# --- escape double quotes ---
escape_dq() {
    printf '%s' "$@" | sed -e 's/"/\\"/g'
}

# --- main function
main() {
    log "Starting main with args: " $(quote "$@")
    while [ $# -gt 0 ]; do
        local cmd="$1"
        case "$cmd" in
            --runas) RUNAS="$2"; shift 2;;
            --rundir) RUNDIR="$2"; shift 2;;
            --) shift; break;;
            *) break;;
        esac
    done

    if [ -z "$RUNDIR" ]; then
        if [ -n "$RUNAS" ]; then
            RUNDIR="/var/tmp/runner-$(id -u $RUNAS)"
        else
            RUNDIR="/var/tmp/runner-$(id -u)"
        fi
    fi
    log "RUNDIR=$RUNDIR RUNAS=$RUNAS"
    export XLRDIR=/opt/xcalar
    export PATH="$XLRDIR/bin:$PATH"

    mkdir -p "$RUNDIR"
    cd "$RUNDIR" || fatal "Unable to chdir to $RUNDIR"
    if [ -n "$RUNAS" ]; then
        chown "$RUNAS" "$RUNDIR"
        log "Runninig su-exec $RUNAS" $(quote "$@")
        su-exec "$RUNAS" "$@"
    else
        log "Runninig " $(quote "$@")
        "$@"
    fi
    rc=$?
    log "Got back rc=$rc"
    return $rc
}

main "$@"
