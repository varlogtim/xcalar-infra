FROM ubuntu:trusty

RUN apt-get update && apt-get install -y curl git build-essential ruby ruby-dev bundler
RUN git clone https://github.com/rcrowley/certified.git /usr/src/certified
RUN cd /usr/src/certified && make install
