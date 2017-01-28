#!/bin/bash

set -x
date > /etc/packer_build_time

rm -f /etc/hostname
