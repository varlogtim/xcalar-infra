#!/bin/bash
#
# shellcheck disable=SC1091,SC2086

set -ex

export XLRINFRADIR=${XLRINFRADIR:-$PWD}
export PATH=$XLRINFRADIR/bin:/opt/xcalar/bin:$HOME/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$PATH
export OUTDIR=${OUTDIR:-$PWD/output}

if [ -n "$JENKINS_URL" ]; then
    if [ -n "$REBUILD_VENV" ]; then
        rm -rf .venv
    fi
    test -d ".venv" || python3 -m venv .venv
    source .venv/bin/activate
    python3 -m pip install -U pip

    pip3 install -U cfn-flip
    pip3 install -U awscli
fi

. infra-sh-lib
. azure-sh-lib
. aws-sh-lib

test -d $OUTDIR || mkdir -p $OUTDIR
rm -rf ${OUTDIR:?}/*

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

    bash -x ../build.sh --osid amzn1 --template $PACKERCONFIG --installer "$INSTALLER" -- -only=${BUILDER} -color=false 2>&1 | tee $OUTDIR/output.txt
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    #-- -only=${BUILDER} -color=false packer.json

    #--> amazon-ebs-amzn1: AMIs were created:
    #us-east-1: ami-0be51e55e6e7c04ca
    #us-west-2: ami-0ebc8804d67bb22bd
    grep -A5 "${BUILDER}: AMIs were created:" $OUTDIR/output.txt | grep "ami-" | tee $OUTDIR/amis.yaml

}

do_deploy_template() {
    cd $XLRINFRADIR/aws/cfn/xdp-standard

    AMI_US_EAST_1=$(awk '/us-east-1: /{print $2}' $OUTDIR/amis.yaml)
    AMI_US_WEST_2=$(awk '/us-west-2: /{print $2}' $OUTDIR/amis.yaml)

    cat > vars/amis.yaml <<-EOF
	ami_us_east_1: ${AMI_US_EAST_1}
	ami_us_west_2: ${AMI_US_WEST_2}
	EOF
    bash -x ./deploy.sh --project xdp-standard --version 2.0.0 --release ${BUILD_NUMBER} --url-file $OUTDIR/template.url
}

do_packer
do_deploy_template

