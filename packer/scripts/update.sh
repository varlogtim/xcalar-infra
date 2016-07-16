#!/bin/bash
# Update the box
APT_PROXY="${APT_PROXY-http://apt-cacher.int.xcalar.com:3142}"
if [ "$(curl -sL -w "%{http_code}\\n" "$APT_PROXY" -o /dev/null)" != "200" ]; then
    unset APT_PROXY
fi

export DEBIAN_FRONTEND=noninteractive
http_proxy=$APT_PROXY apt-get -yqq update
http_proxy=$APT_PROXY apt-get -yqq upgrade
http_proxy=$APT_PROXY apt-get -yqq autoremove
