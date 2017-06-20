#!/bin/bash

export XLRDIR=$PWD
export PATH=$XLRDIR/bin:$PATH

bash -ex bin/build-installers.sh
