#!/bin/bash
set -e
TMPDIR=$(mktemp -d /tmp/awscli-XXXXXX)
cd $TMPDIR
curl -L "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
if ! command -v unzip >/dev/null; then
    sudo yum install -y unzip
fi
unzip awscliv2.zip
ver=$(aws/dist/aws --version | cut -d' ' -f1 | cut -d'/' -f2)
bundle=awscliv2-bundle-${ver}.tar.gz
tar czf $bundle aws
PREFIX=/opt/awscliv2
ITERATION=${ITERATION:-1}

sudo rm -rf $PREFIX
sudo mkdir -p $PREFIX
sudo -H aws/install -i $PREFIX -b /usr/bin
sudo ln -sfn ${PREFIX}/v2/current/bin/aws_completer /usr/bin/
echo 'complete -C /usr/bin/aws_completer aws' | sudo tee /usr/share/bash-completion/completions/aws >/dev/null
cd - >/dev/null

TAR=awscliv2-${ver}-${ITERATION}.tar
tar cvf $TAR  -C / .${PREFIX} ./usr/bin/aws ./usr/bin/aws_completer ./usr/share/bash-completion/completions/aws

rm -rf $TMPDIR
