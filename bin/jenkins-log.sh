#!/bin/bash

jenkins_log() {
    local job_build=($(echo "$1" | sed -r 's@.*job/([A-Za-z0-9_\.-]+)/([0-9]+).*$@\1 \2@'))
    ssh jenkins@jenkins "cat jobs/${job_build[0]}/builds/${job_build[1]}/log"
}

usage() {
    cat << EOF
    usage: $0 job-url

    job-url         A url to a job such as http://jenkins-url/job/SomeJob/30, or a partial url such as:

                    job/SomeJob/30
                    https://jenkins.int.xcalar.com/job/GerritXCETest/15287/
EOF
}

case "$1" in
    http://*) jenkins_log "$1";;
    https://*) jenkins_log "$1";;
    job/*) jenkins_log "$1";;
    *) usage; exit 1;;
esac
exit $?
