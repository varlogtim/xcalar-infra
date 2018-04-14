#!/usr/bin/env bash

export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin

echo $(docker images | grep -E "^$1.*latest" | awk '{print $3}')
