#!/bin/bash

set +e
sudo serivce xcalar stop
sudo service xcalar stop-supervisor
sudo pkill -9 usrnode
sudo pkill -9 xcmonitor
sudo pkill -9 expServer
sudo pkill -9 chidnode
sudo pkill -9 xcmgmtd
set -e
