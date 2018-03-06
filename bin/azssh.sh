#!/bin/bash
set -e

#
# Xcalar internal use only
#
# Xcalar Azure VM TMUX/SSH
#
# Given a public IP, ssh to it in a tmux pane, and use it as an intermediary to
# ssh to the remaining cluster VMs.  Also leave behind an ssh tunnel for easy
# parallel-scp and so on.
#

genCmd() {
    local pw="$1"
    local opts="$2"
    local uname="$3"
    local ip="$4"
    local fPort="$5"
    local hostPre="$6"
    local vm="$7"

    cmd="sshpass -p $pw ssh -A $opts -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null $uname@$ip -L$fPort:${hostPre}$vm:22 sshpass -p $pw ssh -A $opts -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ${hostPre}$vm"
    echo $cmd
}

sshGo() {
    local origPane="$1"
    local pubIp="$2"
    local vmHostPrefix="$3"
    local numVms="$4"
    local userName="$5"
    local pw="$6"
    local fPort="$7"
    local tunnelOnly="$8"

    local opts="-t"

    $tunnelOnly && opts="-NT"
    # for vm in $(seq $numVms -1 0)
    for vm in $(seq 0 $(( $numVms - 1)))
    do
        if [[ $vm -eq 0 ]]
        then
            cmd=$(genCmd "$pw" "$opts" "$userName" "$pubIp" "$fPort" "$vmHostPrefix" "$vm")
            if $tunnelOnly
            then
                $cmd &
            else
                local targetPane=$(tmux new-window -P "$cmd")
                echo "Target window: $targetPane"
            fi
            echo $cmd
        else
            # Something about the tmux ordering requires us to reverse the
            # host ordering to get desired pane sequence
            currVm=$(( $numVms - ${vm} ))
            currPort=$(( $fPort + $currVm ))
            cmd=$(genCmd "$pw" "$opts" "$userName" "$pubIp" "$currPort" "$vmHostPrefix" "$currVm")
            echo $cmd
            if $tunnelOnly
            then
                $cmd &
            else
                tmux split-window -t "$targetPane" "$cmd"
            fi
        fi
        # Prevent "pane too small" while creating
        ! $tunnelOnly && tmux select-layout -t "$targetPane" tiled
        sleep 0.5
    done;

    if $tunnelOnly
    then
        echo "$numVms tunnels created starting at localhost:$fPort"
        echo "Ctrl-C to close tunnels"
        for job in $(jobs -p)
        do
            wait $job
        done
    else
        tmux select-layout -t "$targetPane" tiled
        tmux select-pane -t "$targetPane"
        echo "Use <meta-arrow> to navigate amongst panes (e.g. <ctrl-b down>)"
        echo "Use <meta-z> to zoom pane in/out (e.g. <ctrl-b z>)"
    fi
}

optPubIp=""
optNumVms=""
optUsername=""
optPassword=""
optTunnelOnly=false
optHostPrefix="xdp-standard-xce-vm"
optTunPort="10000"

myName=$(basename $0)

usage()
{
    cat << EOF
    Creates a new tmux window with new panes (one per VM) that SSH to each VM.
    Also sets up ssh tunnels mapped to localhost:<port>.

    Must be run within tmux.

    Example invocation:
        $myName -i 52.250.121.94 -u azureuser -P azpassword -n 8

    Example using tunnel to scp file to VM number 2 through tunnel:
        scp -P 10002 /tmp/tmp.txt azureuser@localhost:/tmp

    Parallel scp to VMs 1 and 2 via tunnel:
        sshpass -p <password> parallel-scp -Avl auser -H localhost:10001 -H localhost:10002 bar.txt /tmp

    Usage: $myName <options>
        -f <port>       Base port for tunneling (default: $optTunPort)
        -i <ip>         Public facing IP of node 0
        -n <numVms>     Total number of VMs
        -p <hostPre>    VM hostname prefix (default: $optHostPrefix)
        -P <password>   VM password
        -t              Set up SSH tunnels only (no interactive shells)
        -u <username>   VM username
EOF
}

while getopts "f:i:p:P:n:u:th" opt; do
  case $opt in
      f) optTunPort="$OPTARG";;
      i) optPubIp="$OPTARG";;
      n) optNumVms="$OPTARG";;
      p) optHostPrefix="$OPTARG";;
      P) optPassword="$OPTARG";;
      t) optTunnelOnly=true;;
      u) optUsername="$OPTARG";;
      *) usage; exit 0;;
  esac
done

if ! $optTunnelOnly && [ ! "$TMUX" ]
then
    echo "Requires running in tmux session. Try:"
    echo "    tmux new"
    echo "then rerun this command"
    exit 1
fi

if [ $# -eq 0 ]; then
   usage
   exit 0
fi

if [[ ! "$optPubIp" || ! "$optNumVms" || ! "$optUsername" ]]
then
    usage
    echo
    echo "Missing required arguments"
    exit 1
fi

shift $(($OPTIND - 1))
posArgs="$1"

$optTunnelOnly && trap 'kill $(jobs -p)' EXIT
sshGo "$TMUX_PANE" "$optPubIp" "$optHostPrefix" "$optNumVms" "$optUsername" "$optPassword" "$optTunPort" "$optTunnelOnly"
