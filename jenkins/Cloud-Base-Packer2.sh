#!/bin/bash

make
cd packer
touch ~/.packer-vars

. ~/lib/xcalar-infra/bin/activate
make cloud-base 
