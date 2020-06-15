#!/bin/bash

build_id=$(curl -s https://jenkins.int.xcalar.com/job/XCETest/lastSuccessfulBuild/buildNumber)
echo "$build_id"

