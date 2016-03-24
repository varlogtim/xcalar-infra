#!/bin/bash

source ~/.gpg.env
export GPG_AGENT_INFO
if [ -S "$(echo $GPG_AGENT_INFO | sed -e 's/:.*$//g')" ]; then
	printf "$(cat ~/.gpg.env); export GPG_AGENT_INFO\n"
	exit 0
fi
gpg-agent --daemon --pinentry-program /usr/bin/pinentry-curses --write-env-file ~/.gpg.env
