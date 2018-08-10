#!/bin/bash

export XLRDIR=$PWD
export PATH=$XLRDIR/bin:$PATH

bash gerrit-reviewers.sh
