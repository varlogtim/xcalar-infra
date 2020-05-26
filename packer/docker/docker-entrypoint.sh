#!/bin/bash
#
# shellcheck disable=SC2164

if [ "$(id -u)" != 0 ]; then
    exec "$@"
    exit 1  # shouldn't reach here
fi

if ! test -e /usr/bin/java; then
    if ! _java_cmd="$(command -v java)"; then
        if [ -z "$_java_cmd" ]; then
            export JAVA_HOME=/opt/xcalar/lib/java8/jre
        fi
    fi
fi
if test -z "$JAVA_HOME" || ! test -e "$JAVA_HOME"; then
    export JAVA_HOME=/opt/xcalar/lib/java8/jre
fi
export PATH=$PATH:${JAVA_HOME}/bin
if ! test -e /usr/bin/java; then
    ln -sfn $JAVA_HOME/bin/java /usr/bin/java
fi

touch /etc/sysconfig/dcc
cat > /etc/sysconfig/dcc <<EOF
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}
CLUSTER=${CLUSTER:-xcalar}
JAVA_HOME=$JAVA_HOME
PATH=$PATH
XLRDIR=/opt/xcalar
EOF

SERVICES="xcalar-sqldf.service xcalar-jupyter.service xcalar-usrnode.service xcalar-caddy.service"
for SVC in $SERVICES; do
    mkdir -p /etc/systemd/system/${SVC}.d || continue
    cat > /etc/systemd/system/${SVC}.d/99-dcc.conf <<EOF
[Service]
EnvironmentFile=/etc/sysconfig/dcc
UnsetEnvironment=PYTHONHOME
${ENVLIST:+Environment=ENVLIST=$ENVLIST}
${ENVLIST:+EnvironmentFile=$ENVLIST}
EOF
done

exec "$@"
