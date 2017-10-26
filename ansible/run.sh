#!/bin/bash

if test -z "$VIRTUAL_ENV"; then
    if ! . ~/.local/lib/xcalar-infra/bin/activate; then
        echo >&2 "Please run make from $PWD/.."
        exit 1
    fi
fi

ansible-playbook --ssh-common-args "-oPubkeyAuthentication=no" -i hosts --ask-pass --ask-become-pass --become "$@"
