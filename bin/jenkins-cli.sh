#!/bin/bash
JENKINS_URL="${JENKINS_URL:-https://jenkins.int.xcalar.com/}"

JENKINS_HOST="${JENKINS_URL#https://}"
JENKINS_HOST="${JENKINS_HOST%/}"
PORT="${PORT:-22022}"

jenkins_cli () {
    ssh -oPort=${PORT} -oUser=${USER} ${JENKINS_HOST} "$@"
}

usage () {
    cat << EOF
usage: $0 [-l list-plugins (list current plugins)] [-n list-plugins (list newest plugins after restart)] -- [jenkins-cli args]

    -l list-plugins   : output currently loaded plugins in plugin:version format
    -n list-plugins   : output updated plugins in plugin:version format

    --

EOF
    exit 1
}

test $# -gt 0 || set -- help

filter () { cat; }

while getopts "hln" opt "$@"; do
    case $opt in
        h) usage;;
        l) filter() { tr -d '()' | awk '{printf "%s:%s\n",$1,$(NF)}'; };;
        n) filter() { sed -re 's/\([0-9].*//g' | awk '{printf "%s:%s\n",$1,$(NF)}'; };;
        -*) break;;
        --) break;;
    esac
done
shift $((OPTIND-1))
jenkins_cli "$@" | filter
