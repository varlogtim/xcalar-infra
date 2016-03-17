#!/bin/bash
DOCKERPWD=$PWD
DOCKERUSER="`id -un`"
SRCDIR=$PWD
if [ `id -u` -ne 0 ]; then sudo "$0" "$@"; exit $?; fi
if [ -z "$APT_PROXY" ]; then echo >&2 "WARNING: \$APT_PROXY not specified in the environment!"; export APT_PROXY=http://apt-cacher:3142; fi
if [ -z "$CONTAINER_USER" ]; then echo >&2 "WARNING: \$CONTAINER_USER not specified in the environment!"; fi
if [ -z "$CONTAINER_UID" ]; then echo >&2 "WARNING: \$CONTAINER_UID not specified in the environment!"; fi
rm -f /etc/profile.d/buildenv.sh
if [ "$(curl -sL -w "%{http_code}\\n" "$APT_PROXY" -o /dev/null)" != "200" ]; then
    unset APT_PROXY
fi

set -ex

# FROM ubuntu:trusty
# MAINTAINER Xcalar <info@xcalar.com>

# ARG APT_PROXY

cd $DOCKERPWD && export DEBIAN_FRONTEND=noninteractive && apt-get update -y && http_proxy=$APT_PROXY apt-get upgrade -y && http_proxy=$APT_PROXY apt-get install -y gcc sg3-utils openssh-server git pmccabe fio libaio1 libaio1-dbg libaio-dev sysstat iotop nmap traceroute valgrind strace libtool m4 wget clang ant openjdk-7-jdk zip unzip doxygen libc6-dbg iperf g++ htop exuberant-ctags zlib1g-dev libeditline-dev libbsd-dev autoconf automake libncurses5-dev devscripts ispell ccache libboost1.55-all-dev libssl-dev libglib2.0-dev libpython2.7-dev libjansson4 libjansson-dev make linux-tools-common linux-tools-generic phantomjs nodejs npm node-less apache2 jq nfs-common mysql-client mysql-server libmysqlclient-dev libevent-dev libboost-test1.55-dev dictionaries-common uuid-dev pxz xz-utils realpath wamerican lcov python-pip node-uglify dpkg-dev || exit $?
## libhdfs3 deps
cd $DOCKERPWD && DEBIAN_FRONTEND=noninteractive http_proxy=$APT_PROXY apt-get install -y cmake libxml2 libxml2-dev libkrb5-dev krb5-user libgsasl7-dev uuid-dev libprotobuf-dev protobuf-compiler debhelper || exit $?
## fpm deps
cd $DOCKERPWD && DEBIAN_FRONTEND=noninteractive http_proxy=$APT_PROXY apt-get install -y librpm3 librpmbuild3 rpm flex bison gdb python2.7-dbg ruby ruby-dev ruby-bundler libruby unixodbc-bin libmyodbc unixodbc-dev curl vim-nox bash-completion bc || exit $?
cd $DOCKERPWD && DEBIAN_FRONTEND=noninteractive http_proxy=$APT_PROXY apt-get install -y --no-install-recommends maven2 || exit $?


cd $DOCKERPWD && printf 'source %s\n\ngem %s' "'https://rubygems.org'" "'fpm'" > /tmp/Gemfile && cd /tmp && bundle install || exit $?

cd $DOCKERPWD && curl -o /usr/bin/gosu -fsSL "https://github.com/tianon/gosu/releases/download/1.7/gosu-$(dpkg --print-architecture)" && chmod +x /usr/bin/gosu || exit $?


cd $DOCKERPWD && for pkg in fake-factory ipdb pytest pytest-ordering enum34 apache_log_parser; do pip install -U ${pkg}; done || exit $?

echo export JAVA_HOME=/usr/lib/jvm/java-7-openjdk-amd64 | tee -a /etc/profile.d/buildenv.sh && source /etc/profile.d/buildenv.sh

cd $DOCKERPWD && grep -q docker /etc/group || groupadd -g 999 docker || exit $?
cd $DOCKERPWD && echo '%sudo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-sudo && chmod 0440 /etc/sudoers.d/99-sudo || exit $?

#### Thrift
cd $DOCKERPWD && rm -rf /usr/src/thrift-0.9.2 && curl -sSL https://www.apache.org/dist/thrift/0.9.2/thrift-0.9.2.tar.gz | tar zx -C /usr/src || exit $?
#COPY ./src/3rd/thrift/thrift.xcalar-build.patch /usr/src/
# 8b.Install the 2906 patch
#RUN cd /usr/src/thrift-0.9.2 && patch -p1 < ../thrift.xcalar-build.patch
cd $DOCKERPWD && cd /usr/src/thrift-0.9.2 && ./configure --without-tests --prefix=/usr --enable-static --disable-shared --enable-boost --enable-silent-rules --without-ruby || exit $?
cd $DOCKERPWD && cd /usr/src/thrift-0.9.2 && mkdir -p /var/tmp/thrift_rootfs && make -j`nproc` DESTDIR=/var/tmp/thrift_rootfs install || exit $?
cd $DOCKERPWD && cd /usr/src && rm -f thrift-dev*.deb thrift-dev*.rpm && fpm -s dir -t deb --name thrift-dev -v 0.9.2 --iteration 3 -C /var/tmp/thrift_rootfs usr/include usr/lib usr/bin && fpm -s deb -t rpm --name thrift-dev -v 0.9.2 --iteration 2 thrift-dev*.deb || exit $?
cd $DOCKERPWD && cd /usr/src && dpkg -i /usr/src/thrift*.deb || exit $?

# 12.  Download, build, & install pmd
cd $SRCDIR && curl -sSL http://repo.xcalar.net/patches/CPD.java.patch > /usr/src/CPD.java.patch && cd - || exit $?
cd $DOCKERPWD && rm -rf /usr/src/pmd-src-5.0.5* && wget -q -O /usr/src/pmd-src-5.0.5.zip "http://downloads.sourceforge.net/project/pmd/pmd/5.0.5/pmd-src-5.0.5.zip?r=http%3A%2F%2Fsourceforge.net%2Fprojects%2Fpmd%2Ffiles%2Fpmd%2F5.0.5%2F&ts=1388189959&use_mirror=hivelocity" && cd /usr/src && unzip -q pmd-src-5.0.5.zip && rm -f pmd-src-5.0.5.zip && cd /usr/src/pmd-src-5.0.5 && patch -p1 < ../CPD.java.patch && mvn compile && cd target/classes && jar cf /usr/share/java/pmd-5.0.5-xlr1.jar . && rm -f /usr/share/java/pmd.jar && ln -sfn pmd-5.0.5-xlr1.jar /usr/share/java/pmd.jar && rm -f pmd*.deb pmd*.rpm && fpm -s dir -t deb --name pmd --version 5.0.5 --iteration 1 --depends openjdk-7-jre-headless -C / usr/share/java/pmd-5.0.5-xlr1.jar usr/share/java/pmd.jar && fpm -s dir -t rpm --name pmd --version 5.0.5 --iteration 1 --depends java-headless -C / usr/share/java/pmd-5.0.5-xlr1.jar usr/share/java/pmd.jar || exit $?

DOCKERPWD="/usr/src"
echo export LIBHDFS3=/usr/src/libhdfs3 | tee -a /etc/profile.d/buildenv.sh && source /etc/profile.d/buildenv.sh
cd $DOCKERPWD && rm -rf $LIBHDFS3 && git clone -q https://github.com/PivotalRD/libhdfs3.git $LIBHDFS3 && mkdir -p $LIBHDFS3/build && cd $LIBHDFS3 && git checkout -f tags/v2.2.31 && cd $LIBHDFS3/build && ../bootstrap --enable-boost --prefix=/usr && make -j`nproc` DESTDIR=/var/tmp/libhdfs3 install && rm -f /usr/src/libhdfs3*.deb /usr/src/libhdfs3*.rpm && fpm -s dir -t deb --name libhdfs3-dev --version 2.2.31 --iteration 3 -C /var/tmp/libhdfs3 usr && mv *.deb /usr/src || exit $?

cd $DOCKERPWD && for i in libhdfs3*.deb; do fpm -s deb -t rpm "$i"; done || exit $?
cd $DOCKERPWD && dpkg -i libhdfs3*.deb || exit $?

cd $DOCKERPWD && if [ -n "$CONTAINER_USER" ]; then usermod -aG sudo $CONTAINER_USER; fi || exit $?
cd $DOCKERPWD && if [ -n "$CONTAINER_USER" ]; then usermod -aG docker $CONTAINER_USER; fi || exit $?
cd $DOCKERPWD && if [ -n "$CONTAINER_USER" ]; then usermod -aG disk $CONTAINER_USER; fi || exit $?
cd $DOCKERPWD && mkdir -p /var/opt/xcalar /opt/xcalar /var/opt/xcalarTest || exit $?
cd $DOCKERPWD && if [ -n "$CONTAINER_USER" ]; then chown $CONTAINER_USER:$CONTAINER_USER /var/opt/xcalar /var/opt/xcalarTest /opt/xcalar ; else chmod 0777 /var/opt/xcalar /opt/xcalar /var/opt/xcalarTest; fi || exit $?

cd $DOCKERPWD && echo 'add-auto-load-safe-path /' | tee -a /etc/gdb/gdbinit || exit $?
cd $SRCDIR && curl -sSL http://repo.xcalar.net/patches/conf/xcalar-sysctl.conf > /etc/sysctl.d/99-xcalar.conf && cd - || exit $?
cd $SRCDIR && curl -sSL http://repo.xcalar.net/patches/conf/xcalar-limits.conf > /etc/security/limits.d/99-xcalar.conf && cd - || exit $?
cd $SRCDIR && curl -sSL http://repo.xcalar.net/patches/conf/xcalar-logrotate.conf > /etc/logrotate.d/xcalar && cd - || exit $?
cd $SRCDIR && curl -sSL http://repo.xcalar.net/patches/conf/xcalar-rsyslog.conf   > /etc/rsyslog.d/42-xcalar.conf && cd - || exit $?

# ARG CONTAINER_USER
# ARG CONTAINER_UID

# EXPOSE 80 443 18552-18567 5000-5015 9090

#cd $SRCDIR && cp -a ./bin/docker-entrypoint.sh / && cd - || exit $?

# ENTRYPOINT ["/init"]
# CMD ["/bin/bash","-l"]
#Entrypoint CMD
# "/init"  "/bin/bash" "-l"
