#!/bin/bash
#
# shellcheck disable=SC2164

if [ "$(id -u)" != 0 ]; then
    exec "$@"
    exit 1  # shouldn't reach here
fi

SERVICES="xcalar-usrnode.service xcalar-caddy.service"

touch /etc/sysconfig/dcc
for SVC in $SERVICES; do
    mkdir -p /etc/systemd/system/${SVC}.d || continue
    cat > /etc/systemd/system/${SVC}.d/99-dcc.conf <<EOF
[Service]
Environment=AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}
Environment=CLUSTER=${CLUSTER:-xcalar}
EnvironmentFile=/etc/sysconfig/dcc
${ENVLIST:+Environment=ENVLIST=$ENVLIST}
${ENVLIST:+EnvironmentFile=$ENVLIST}
EOF
done

exec "$@"
