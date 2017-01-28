#!/bin/bash
REPOPKG=puppetlabs-release-pc1-el-7.noarch.rpm
yum localinstall -y http://yum.puppetlabs.com/$REPOPKG
yum install -y yum-utils puppet-agent epel-release curl wget tar gzip
