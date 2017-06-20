#!/bin/bash

set -ex
cd $SRCDIR
mkdir -p $DSTDIR
rsync --exclude='xcalar' --exclude='./.config' \
      --exclude='.ccache' --exclude='workspace' \
      --exclude='builds' \
      --delete --delete-excluded -avr ./ $DSTDIR

##echo "Backing up $SOURCE => gs://$BUCKET/$DEST/..."
##mkdir -p $HOME/.cache/duplicity
##duplicity --progress -v4 --allow-source-mismatch $SOURCE gs://$BUCKET/$DEST
