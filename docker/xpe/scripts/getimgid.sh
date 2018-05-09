#!/usr/bin/env bash

# gets full image id of given image pass as parameter.
# if no tag given and there are multiple by that name,
# will give id of the image tagged latest
# example:
#   bash getimgid.sh xdpce
# returns image id of xdpce:latest
#   bash getimgid.sh xdpce:latest
# returns image id of xdpce:latest
#   bash getimgid.sh xdpce:177
# returns image id of xdpce tagged 177

export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin

docker image inspect $1 -f '{{ .Id }}'
