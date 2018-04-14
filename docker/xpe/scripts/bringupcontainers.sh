#!/usr/bin/env bash

docker start xdpce
docker start grafana_graphite || true

# todo: proper verification that containers up
