#!/bin/sh

date > /etc/vagrant_box_build_time

rm -f /etc/hostname
_HOST="$(hostname)"
sed -i -e "/$_HOST/d" /etc/hosts
