#!/bin/bash

set -e

SMP=${SMP:-2}
MEM=${MEM:-1024M}
FORCE=false

die() {
    echo >&2 "ERROR: $1"
    exit 1
}

usage() {
    cat << EOF
    usage: $(basename $0) [-smp #] [-mem #M] [--serial] [--image src.qcow2]
              [--clone clone.qcow2] [-f|--force (overwrite existing clone)]
              -- [-qemu-arg [value,..]]

    defaults:
        -smp $SMP
        -mem $MEM
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        -smp) SMP="$1" ; shift;;
        -m) MEM="$1" ; shift;;
        --image) IMAGE="$1"; shift;;
        --clone) CLONE="$1" ; shift;;
        -f|--force) FORCE=true ;;
        -h|--help) usage;;
        --serial) ARGS+=(-serial mon:stdio);;
        --) break ;;
        --*) die "Unknown argument $cmd" ;;
        -*) break ;;
        *)
            if ! file "$cmd" | grep -q 'QEMU QCOW Image'; then
                die "Unrecognized file or argument: $cmd"
            fi
            IMAGE="$cmd"
            ;;
    esac
done

[ -n "$IMAGE" ] || die "No image specified. Use --image, optionally combined with --clone"

if [ -r "$IMAGE" ]; then
    IMAGE_TO_USE="$IMAGE"
elif [[ $IMAGE =~ ^http[s]?:// ]]; then
    IMAGE_TO_USE="$(basename "${IMAGE%\?*}")"
    echo >&2 "NOTE: Downloading $IMAGE_TO_USE from $IMAGE"
    curl -fsSL "$IMAGE" -o "$IMAGE_TO_USE"
else
    die "Image $IMAGE not found"
fi

if [ -n "$CLONE" ]; then
    if ! [ -e "$CLONE" ] || $FORCE; then
        echo >&2 "NOTE: Cloning existing image"
        qemu-img create -f qcow2 -b "$IMAGE_TO_USE" "$CLONE"
    else
        echo >&2 "NOTE: Using existing clone $CLONE of image ${IMAGE_TO_USE}. Use --force to recreate it"
    fi
    IMAGE_TO_USE="$CLONE"
elif ! [ -w "$IMAGE_TO_USE" ]; then
    die "$IMAGE_TO_USE is not writable. Please fix the permissions, or use --clone"
fi

qemu-system-x86_64 -name $(basename $IMAGE_TO_USE .qcow2) -vnc 127.0.0.1:5656 \
    -drive file=${IMAGE_TO_USE},if=virtio,cache=writeback,discard=ignore,format=qcow2 \
    -m ${MEM} \
    -smp ${SMP} \
    -machine type=pc,accel=kvm \
    -device virtio-net,netdev=forward,id=net0 \
    -boot once=d \
    -netdev user,hostfwd=tcp::2222-:22,id=forward  "${ARGS[@]}" "$@"
    #-cdrom /root/packer/packer_cache/bbd74514a6e11bf7916adb6b0bde98a42ff22a8f853989423e5ac064f4f89395.iso
