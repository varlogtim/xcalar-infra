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
$0 [-l list current plugins] [-n list newest plugins after restart] [-h help] -- [jenkins-cli args]
EOF
    exit 1
}

test $# -gt 0 || set -- help

filter () { cat; }

while getopts "ln" opt "$@"; do
    case $opt in
        h) usage;;
        l) filter() { tr -d '()' | awk '{printf "%s:%s\n",$1,$(NF)}'; };;
        n) filter() { sed -re 's/\([0-9].*//g' | awk '{printf "%s:%s\n",$1,$(NF)}'; };;
        -*) usage;;
        --) break;;
    esac
done
shift $((OPTIND-1))
jenkins_cli "$@" | filter
