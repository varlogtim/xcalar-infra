#!/bin/bash

. /etc/default/grub

GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX// scsi_mod.use_blk_mq=?/} scsi_mod.use_blk_mq=Y"

sed -i '/GRUB_CMDLINE_LINUX/d' /etc/default/grub
cat >> /etc/default/grub <<EOF
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX"
EOF

grub2-mkconfig -o /boot/grub2/grub.cfg
grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg
