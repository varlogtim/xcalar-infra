#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import json
import logging
import math
import os
import random
import re

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_artifacts import JenkinsArtifacts, JenkinsArtifactsData
from py_common.mongo import MongoDB
from py_common.sorts import nat_sort

class XDUnitTestCoverage(object):
    ENV_PARAMS = {}
    GZIPPED = re.compile(r".*\.gz\Z")

    def __init__(self, *, path):
        self.logger = logging.getLogger(__name__)
        self.cfg = EnvConfiguration(XDUnitTestCoverage.ENV_PARAMS)
        self.coverage_data = self._load_json(path=path)
        self.url_to_coverage = {}
        for item in self.coverage_data:
            url = item['url']
            self.logger.debug("url: {}".format(url))
            totalLen = len(item['text'])
            self.logger.debug("total length: {}".format(totalLen))
            coveredLen = 0
            for cvrd in item['ranges']:
                coveredLen += (int(cvrd['end']) - int(cvrd['start']) - 1)
            self.logger.debug("covered length: {}".format(coveredLen))
            coveredPct = 100*coveredLen/totalLen
            self.logger.debug("covered pct: {}".format(coveredPct))
            self.url_to_coverage[url] = {'total_len': totalLen,
                                         'covered_len': coveredLen,
                                         'covered_pct': coveredPct}

    def _load_json(self, *, path):
        if not os.path.exists(path):
            # Try gzipped form
            zpath = "{}.gz".format(path)
            if not os.path.exists(zpath):
                err = "neither {} nor {} exist".format(path, zpath)
                self.logger.error(err)
                raise FileNotFoundError(err)
            path = zpath

        if self.GZIPPED.match(path):
            with gzip.open(path, "rb") as fh:
                return json.loads(fh.read().decode("utf-8"))
        with open(path, "r") as fh:
            return json.load(fh)

    def get_data(self):
        return self.url_to_coverage

class XDUnitTestArtifacts(JenkinsArtifacts):
    ENV_PARAMS = {"XD_UNIT_TEST_JOB_NAME":
                        {"default": "XDUnitTest",
                         "required":True},
                  "XD_UNIT_TEST_ARTIFACTS_ROOT":
                        {"default": "/netstore/qa/coverage/XDUnitTest",
                         "required":True} }

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(XDUnitTestArtifacts.ENV_PARAMS)
        super().__init__(job_name=cfg.get("XD_UNIT_TEST_JOB_NAME"),
                         dir_path=cfg.get("XD_UNIT_TEST_ARTIFACTS_ROOT"))


class XDUnitTestArtifactsData(JenkinsArtifactsData):

    ENV_PARAMS = {"XD_UNIT_TEST_COVERAGE_FILE_NAME":
                        {"default": "coverage.json",
                         "required": True} }

    def __init__(self, *, artifacts):
        """
        Initializer.
    
        Required parameters:
            artifacts:  XDUnitTestArtifacts instance

        Environment Parameters:
            XD_UNIT_TEST_COVERAGE_FILE_NAME:
                    name of coverage file (default: coverage.json)
        """
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(XDUnitTestArtifactsData.ENV_PARAMS)
        self.coverage_file_name = cfg.get("XD_UNIT_TEST_COVERAGE_FILE_NAME")
        self.artifacts = artifacts
        super().__init__(jenkins_artifacts=self.artifacts, add_commits=True)

    def update_build(self, *, bnum, log=None):
        """
        Return coverage info for a specific build.
        """
        try:
            path = os.path.join(self.artifacts.artifacts_directory_path(bnum=bnum),
                                self.coverage_file_name)
            data = {}
            for url,coverage in XDUnitTestCoverage(path=path).get_data().items():
                data[MongoDB.encode_key(url)] = coverage
            return {'coverage': data}
        except FileNotFoundError as e:
            return None

    def xd_versions(self):
        """
        Return available XD versions for which we have data.
        XXXrs - version/branch :|
        """
        return self.branches(repo='XD_GIT_REPOSITORY')

    def builds(self, *, xd_versions=None,
                        first_bnum=None,
                        last_bnum=None,
                        reverse=False):

        return self.find_builds(repo='XD_GIT_REPOSITORY',
                                branches=xd_versions,
                                first_bnum=first_bnum,
                                last_bnum=last_bnum,
                                reverse=reverse)

    def _get_coverage_data(self, *, bnum):
        data = self.get_data(bnum=bnum)
        if not data:
            return None
        return data.get('coverage', None)

    def filenames(self, *, bnum):
        coverage = self._get_coverage_data(bnum=bnum)
        if not coverage:
            return None

        # Reduce a URL to just a filename:
        filenames = []
        for key in coverage.keys():
            url = MongoDB.decode_key(key)
            fields = url.split('/')
            if len(fields) < 2:
                raise Exception("Incomprehensible: {}".format(url))
            filename = "{}/{}".format(fields[-2], fields[-1])
            if filename in filenames:
                raise Exception("Duplicate: {}".format(filename))
            filenames.append(filename)
        return sorted(filenames)

    def coverage(self, *, bnum, filename):
        coverage = self._get_coverage_data(bnum=bnum)
        if not coverage:
            return None
        for key,data in coverage.items():
            url = MongoDB.decode_key(key)
            if filename in url:
                return coverage[key].get('covered_pct', None)
        return None


if __name__ == '__main__':
    print("Compile check A-OK!")

    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    art = XDUnitTestArtifacts()
    data = XDUnitTestArtifactsData(artifacts = art)
    """
    for version in data.xd_versions():
        print("{} ==========".format(version))
        builds = data.builds(xd_versions=[version])
        print(builds)
        for bnum in builds:
            print("{} ----------".format(bnum))
            for filename in data.filenames(bnum=bnum):
                print("{}: {}".format(filename, data.coverage(bnum=bnum, filename=filename)))
    """
    print("let update thread run a little...")
    data.start_update_thread()
    import time
    time.sleep(30)
    print("stop update thread")
    data.stop_update_thread()
    print("DONE")
