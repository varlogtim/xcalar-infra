#!/bin/bash
set -e

OSID=$(osid)
case "$OSID" in
    amzn2)
        sudo amazon-linux-extras install -y docker
        sudo mkdir -p /usr/share/bash-completion/completions
        sudo ln -sfn /usr/share/bash-completion/docker /usr/share/bash-completion/completions/docker
        ;;
    *)
        curl -sSL https://get.docker.com | sudo bash
        ;;
esac
sudo yum install --enablerepo='xcalar*' -y docker-compose
sudo mkdir -p /etc/systemd/system/docker.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/docker.service.d/docker-ephemeral-root.conf >/dev/null
[Unit]
Wants=ephemeral-disk.service
After=ephemeral-disk.service

[Service]
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStartPre=/bin/mkdir -p /ephemeral/data/docker /etc/docker
ExecStartPre=/bin/bash -c "echo '{\"data-root\": \"/ephemeral/data/docker\"}' > /etc/docker/daemon.json"
EOF
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo usermod -aG docker $(id -un 1000) || true
