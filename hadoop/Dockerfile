FROM hadoop-docker
MAINTAINER Xcalar, Inc <info@xcalar.com>

ENV HADOOP_PREFIX=/usr/local/hadoop
WORKDIR $HADOOP_PREFIX

RUN curl -sSL http://repo.xcalar.net/data/qa.tar.gz | tar zxf - -C /tmp && \
    /etc/bootstrap.sh && \
    until bin/hadoop fs -mkdir /datasets; do sleep 10; done && \
    bin/hadoop fs -copyFromLocal /tmp/qa /datasets/ && \
    rm -rf /tmp/qa && \
    source $HADOOP_PREFIX/etc/hadoop/hadoop-env.sh && \
    ./sbin/stop-yarn.sh && \
    ./sbin/stop-dfs.sh

