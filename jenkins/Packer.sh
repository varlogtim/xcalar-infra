#!/bin/bash
#
# shellcheck disable=SC1091,SC2086

set -ex

export XLRINFRADIR=${XLRINFRADIR:-$PWD}
export PATH=$XLRINFRADIR/bin:/opt/xcalar/bin:$HOME/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$PATH
export OUTDIR=${OUTDIR:-$PWD/output}

if [ -n "$JENKINS_URL" ]; then
    if test -e .venv/bin/python2; then
        REBUILD_VENV=true
    fi

    if [ -n "$REBUILD_VENV" ]; then
        rm -rf .venv
    fi
fi

test -d ".venv" || python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -U pip

pip3 install -U cfn-flip
pip3 install -U awscli

. infra-sh-lib
. aws-sh-lib

test -d $OUTDIR || mkdir -p $OUTDIR

do_parse_yaml() {
    local yaml="${1:-$OUTDIR/amis.yaml}"
    AMI_US_EAST_1=$(awk '/us-east-1: /{print $2}' $yaml)
    AMI_US_WEST_2=$(awk '/us-west-2: /{print $2}' $yaml)
}


do_packer() {
    if [ -d "$INSTALLER" ]; then
        echo "INSTALLER=$INSTALLER is a directory. Looking for an installer."
        INSTALLER=$(find $INSTALLER/ -type f -name 'xcalar-*-installer' | grep prod | head -1)
    fi

    if ! [ -r "$INSTALLER" ]; then
        echo >&2 "ERROR: Unable to find installer INSTALLER=$INSTALLER"
        exit 1
    fi

    cd $XLRINFRADIR/packer/aws
    #export INSTALLER_URL=$(installer-url.sh -d s3 $INSTALLER)
    #cfn-flip < $PACKERCONFIG > packer.json

    INSTALLER_VERSION_BUILD=($(version_build_from_filename "$(filename_from_url "$INSTALLER")"))
    VERSION=${INSTALLER_VERSION_BUILD[0]}

    bash -x ../build.sh --osid amzn1 --template $PACKERCONFIG --installer "$INSTALLER" -- ${BUILDER:+-only=${BUILDER}} -var license="${LICENSE}" -color=false 2>&1 | tee $OUTDIR/output.txt
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi

    grep -A5 "${BUILDER}: AMIs were created:" $OUTDIR/output.txt | grep "ami-" | tee $OUTDIR/amis.yaml
    do_parse_yaml $OUTDIR/amis.yaml
}

do_upload_template() {
    cd $XLRINFRADIR/aws/cfn
    cat > vars/amis.yaml <<-EOF
	ami_us_east_1: ${AMI_US_EAST_1}
	ami_us_west_2: ${AMI_US_WEST_2}
	EOF
    dc2 upload --project ${PROJECT:-xdp-awsmp} --version ${VERSION} --release ${BUILD_NUMBER} --url-file $OUTDIR/template.url
}

if [ "${DO_PACKER:-true}" == true ]; then
    do_packer
else
    if ! test -e $OUTDIR/amis.yaml; then
        curl -fsSL ${JOB_URL}/lastSuccessfulBuild/artifact/output/amis.yaml -o $OUTDIR/amis.yaml
    fi
    do_parse_yaml $OUTDIR/amis.yaml
fi
do_upload_template
