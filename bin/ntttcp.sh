#!/bin/bash

vm="${1:-vm1}"
port=${2:-6001}
ip=$(getent hosts $vm | awk '{print $1}') || exit 1

_ssh() {
	ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no "$@"
}

URL=http://repo.xcalar.net/deps/ntttcp-1.4.0.tar.gz

if ! command -v ntttcp >/dev/null; then
   curl -fsSL $URL | tar zxf -
   chmod +x ntttcp
fi
if ! _ssh $vm command -v ntttcp; then
   curl $URL | _ssh $ip tar zxf
   _ssh $ip chmod +x ntttcp
fi

_ssh $vm bash -c 'tmux kill-session -t ./ntttcp 2>/dev/null || true' || true
_ssh $vm tmux new-session -d -s ntttcp ./ntttcp -r -m 8,0,$ip --show-tcp-retrans --show-nic-packets eth0 --show-dev-interrupts mlx4 -V -p $port || exit 1

sleep 5

ntttcp -s $ip --show-tcp-retrans --show-nic-packets eth0 --show-dev-interrupts mlx4 -V -p $port
_ssh $vm bash -c 'tmux kill-session -t ntttcp 2>/dev/null || true' || true

