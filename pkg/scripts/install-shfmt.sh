#!/bin/bash
URL=https://mvdan.cc/sh/cmd/shfmt
NAME=shfmt
VERSION=2.1.0
ITERATION=${BUILD_NUMBER:-1}
DESC="A shell parser, formatter and interpreter."
LICENSE=BSD3

. install-golang-tool.sh

