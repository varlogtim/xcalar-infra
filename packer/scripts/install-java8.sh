#!/bin/bash
set -e

install_java8() {
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get purge -y openjdk-7-jdk || true
        apt-get install -y openjdk-8-jdk
        export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
    else
        yum remove -y java-1.7.0-openjdk-headless java-1.7.0-openjdk || true
        yum install -y java-1.8.0-openjdk-devel
        export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk.x86_64
    fi

    cat > /etc/profile.d/zjava.sh <<EOF
export JAVA_HOME=$JAVA_HOME
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF
}

install_java8
