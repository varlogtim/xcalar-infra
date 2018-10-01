#!/bin/bash

JENKINS_URL="${JENKINS_URL:-https://jenkins.int.xcalar.com/}"
JENKINS_URL="${JENKINS_URL%/}"

JENKINS_HOST="${JENKINS_URL#https://}"
JENKINS_HOST="${JENKINS_URL#http://}"
JENKINS_HOST="${JENKINS_HOST%/}"

PORT="${PORT:-22022}"

jenkins_cli () {
    ssh -oPort=${PORT} -oUser=${USER} ${JENKINS_HOST} "$@"
}

cmd_list_nodes() {
    curl -fsSL "${JENKINS_URL}/computer/api/json"
}

filter () { cat; }

usage () {
    cat << EOF
usage: $0 [-l list-plugins (list current plugins)] [-c command] [-n list-plugins (list newest plugins after restart)] [list-nodes] -- [jenkins-cli args]

    -l list-plugins   : output currently loaded plugins in plugin:version format
    -n list-plugins   : output updated plugins in plugin:version format
    -c list-nodes     : list all nodes as json. use jq for extra processing. eg:
            jq -r '.computer[].displayName'
            jq -r '[.computer[]|{displayName,offline}]'

    --

EOF
    exit 1
}

test $# -gt 0 || set -- help


while getopts "hlnc:" opt "$@"; do
    case $opt in
        h) usage;;
        l) filter() { tr -d '()' | awk '{printf "%s:%s\n",$1,$(NF)}'; };;
        n) filter() { sed -re 's/\([0-9].*//g' | awk '{printf "%s:%s\n",$1,$(NF)}'; };;
        c) eval cmd_${OPTARG//-/_}; exit;;
        -*) break;;
        --) break;;
    esac
done
shift $((OPTIND-1))
jenkins_cli "$@" | filter
