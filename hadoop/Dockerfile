FROM sequenceiq/hadoop-docker:2.7.1
MAINTAINER Xcalar, Inc <info@xcalar.com>

ENV HADOOP_PREFIX=/usr/local/hadoop
WORKDIR $HADOOP_PREFIX

RUN curl -sSL -O http://repo.xcalar.net/deps/jdk-8u73-linux-x64.rpm && rpm -Uvh jdk-8u73-linux-x64.rpm  && rm jdk-8u73-linux-x64.rpm
ENV JAVA_HOME=/usr/java/default
RUN rm lib/native/*
RUN curl -sSL http://repo.xcalar.net/deps/hadoop-native-64-2.7.1.tar | tar xf - -C lib/native
RUN curl -sSL http://repo.xcalar.net/data/qa.tar.gz | tar zxf - -C /tmp && \
    /etc/bootstrap.sh && \
    until bin/hadoop fs -mkdir /datasets; do sleep 10; done && \
    bin/hadoop fs -copyFromLocal /tmp/qa /datasets/ && \
    rm -rf /tmp/qa && \
    source $HADOOP_PREFIX/etc/hadoop/hadoop-env.sh && \
    ./sbin/stop-yarn.sh && \
    ./sbin/stop-dfs.sh
