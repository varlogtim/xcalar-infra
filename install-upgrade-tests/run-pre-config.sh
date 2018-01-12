#!/bin/bash

DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
DIR="$(readlink -f $DIR)"

. $DIR/integration-sh-lib

MY_NAME=$(basename $0)
echo '#'
echo "# $MY_NAME $@"
echo '#'

usage() {
    say "usage: $0 [-h|--help] -i <input file> -f <test JSON file>"
    say "-i - input file describing the cluster"
    say "-f - JSON file describing the cluster and the tests to run"
    say "-h|--help - this help message"
}

parse_args() {

    if [ -z "$1" ]; then
        usage
        exit 1
    fi

    while test $# -gt 0; do
        cmd="$1"
        shift
        case $cmd in
            --help|-h)
                usage
                exit 1
                ;;
            -i)
                INPUT_FILE="$1"
                shift

                if [ ! -e "$INPUT_FILE" ]; then
                    say "Input config file $INPUT_FILE does not exist"
                    exit 1
                fi
                . $INPUT_FILE
                ;;
            -f)
                TEST_FILE="$1"
                shift

                if [ ! -e "$TEST_FILE" ]; then
                    say "Test config file $TEST_FILE does not exist"
                    exit 1
                fi
                ;;
            *)
                say "Unknown command $cmd"
                usage
                exit 1
                ;;
        esac
    done

    if [ -z "$TEST_FILE" ]; then
        say "No test file specified"
        exit 1
    fi

    if [ -z "$INPUT_FILE" ]; then
        say "No input file specified"
        exit 1
    fi
}

parse_test_file() {
    task "Parsing test config file"

    t_start="$(date +%s)"
    TEST_NAME=$(jq -r ".TestName" $TEST_FILE)

    INSTALLER_FILE=$(jq -r ".InstallerFile.PreConfigFile" $TEST_FILE)
    INSTALLER_SRC=$(jq -r ".InstallerFile.Source" $TEST_FILE)
    eval INSTALLER_SRC=$INSTALLER_SRC
    INSTALLER_SRC=$(readlink -f "$INSTALLER_SRC")

    NFS_TYPE=$(jq -r .Build.NfsType $TEST_FILE)
    NFS_SERVER=$(jq -r .Build.NfsServer $TEST_FILE)
    NFS_MOUNT=$(jq -r .Build.NfsMount $TEST_FILE)
}

parse_args "$@"

create_cache_dir || die 1 "Unable to create cache dir"

parse_test_file

hosts_array=($(echo $EXT_CLUSTER_IPS | sed -e 's/,/\n/g'))

task "Getting config tarball"
get_installer_file || die 1 "Unable to get installer file"

task "Copying tarball to cluster hosts"
pscp_cmd "${TMPDIR}/${INSTALLER_FILE}" ""

task "Unpacking config tarball"
pssh_cmd "tar xvzf ./${INSTALLER_FILE}"

task "Running pre-config"
test_user="$(id -un)"
case "$NFS_TYPE" in
    reuse|REUSE|ext|EXT)
        pssh_cmd "sudo mkdir -p /mnt/xcalar"
        pssh_cmd "! mountpoint -q /mnt/xcalar && sudo mount -t nfs ${NFS_SERVER}:${NFS_MOUNT}/${TEST_NAME}-${TEST_ID}/sub /mnt/xcalar"
        ;;
esac

pssh_cmd "echo 'XCE_USER=${test_user}' > config/setup.txt"
pssh_cmd "echo 'XCE_GROUP=${test_user}' >> config/setup.txt"
pssh_cmd "sudo config/pre-config.sh" || die 1 "Unable to run pre-config.txt"

