#!/bin/bash
set -e

if [ $(id -u) != 0 ]; then
	echo >&2 "ERROR: Must run as root"
	exit 3
fi

CUDA_VERSION=${CUDA_VERSION:-10}
BASE_URL="${BASE_URL:-https://storage.googleapis.com/repo.xcalar.net/deps/nvidia}"
CUDA_COMPONENTS="${CUDA_COMPONENTS:-cuda_10.1.243_418.87.00_linux.run cudnn-10.0-linux-x64-v7.6.5.32.tgz}"
PYTHON_PKGS="${PYTHON_PKGS:-tensorflow-gpu==1.13.1 pandas==0.22 keras==2.4.3}"

## Install cuda deps
TMP=$(mktemp -d -t cuda.XXXXXX)
cd "$TMP"

for ii in $CUDA_COMPONENTS; do
	curl -f -L -O "${BASE_URL}/${ii}"
	case "$ii" in
		cuda_*.run)
			yum install -y dkms kernel-devel
			bash "$ii" --silent --toolkit --driver
			BN=$(basename $(readlink -f /usr/local/cuda))
			echo "$(readlink -f /usr/local/cuda)/lib64" > /etc/ld.so.conf.d/${BN}.conf
			ldconfig
			;;
		cudnn*.tgz)
			tar zxf "$ii" --strip-components=1 -C /usr/local/cuda/
			ldconfig
			;;
	esac
done
cd -
rm -rf "$TMP"

curl -fsSL https://storage.googleapis.com/repo.xcalar.net/scripts/nvidia-check.sh -o /usr/local/bin/nvidia-check.sh
chmod +x /usr/local/bin/nvidia-check.sh
set +e
/usr/local/bin/nvidia-check.sh
set -e
## Install new packages
/opt/xcalar/bin/python3 -m pip install $PYTHON_PKGS \
	-c <(sed '/tensorflow/d; /pandas/d' /opt/xcalar/share/doc/xcalar-python36-3.*/requirements.txt)
