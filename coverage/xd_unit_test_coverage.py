#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import gzip
import json
import logging
import math
import os
import random
import re

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_artifacts import JenkinsArtifacts, JenkinsArtifactsData
from py_common.mongo import MongoDB

from coverage.file_groups import FileGroupsMixin

class XDUnitTestCoverage(object):
    ENV_PARAMS = {}
    GZIPPED = re.compile(r".*\.gz\Z")

    def __init__(self, *, path):
        self.logger = logging.getLogger(__name__)
        self.cfg = EnvConfiguration(XDUnitTestCoverage.ENV_PARAMS)
        self.coverage_data = self._load_json(path=path)
        self.url_to_coverage = {}
        self.total_total_len = 0
        self.total_covered_len = 0
        for item in self.coverage_data:
            url = item['url']
            self.logger.debug("url: {}".format(url))
            totalLen = len(item['text'])
            self.total_total_len += totalLen
            self.logger.debug("total length: {}".format(totalLen))
            coveredLen = 0
            for cvrd in item['ranges']:
                coveredLen += (int(cvrd['end']) - int(cvrd['start']) - 1)
            self.total_covered_len += coveredLen
            self.logger.debug("covered length: {}".format(coveredLen))
            coveredPct = 100*coveredLen/totalLen
            self.logger.debug("covered pct: {}".format(coveredPct))
            self.url_to_coverage[url] = {'total_len': totalLen,
                                         'covered_len': coveredLen,
                                         'covered_pct': coveredPct}
        total_pct = 0
        if self.total_total_len:
            total_pct = 100*self.total_covered_len/self.total_total_len
        self.url_to_coverage['Total'] = {'total_len': self.total_total_len,
                                         'covered_len': self.total_covered_len,
                                         'covered_pct': total_pct}

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

    def total_coverage_pct(self):
        if not self.total_total_len:
            return 0
        return 100*self.total_covered_len/self.total_total_len

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


class XDUnitTestArtifactsData(FileGroupsMixin, JenkinsArtifactsData):

    # XXXrs - temporary static config.
    FILE_GROUPS = {"Critical Files": [
        "/ts/components/datastore/DS.js",
        "/ts/components/datastore/DSForm.js",
        "/ts/components/datastore/DSPreview.js",
        "/ts/components/datastore/DSTable.js",
        "/ts/components/datastore/DSTargetManager.js",
        "/ts/components/datastore/FileBrowser.js",

        "/ts/components/dag/DagGraph.js",
        "/ts/components/dag/DagGraphExecutor.js",
        "/ts/components/dag/DagLineage.js",
        "/ts/components/dag/DagList.js",
        "/ts/components/dag/DagNodeExecutor.js",
        "/ts/components/dag/DagNodeMenu.js",
        "/ts/components/dag/DagPanel.js",
        "/ts/components/dag/DagParamManager.js",
        "/ts/components/dag/DagQueryConverter.js",
        "/ts/components/dag/DagSubGraph.js",
        "/ts/components/dag/DagTab.js",
        "/ts/components/dag/DagTabManager.js",
        "/ts/components/dag/DagTabUser.js",
        "/ts/components/dag/DagTable.js",
        "/ts/components/dag/DagTblManager.js",
        "/ts/components/dag/DagView.js",
        "/ts/components/dag/DagViewManager.js",
        "/ts/components/dag/node/DagNode.js",

        "/ts/components/sql/SQLDagExecutor.js",
        "/ts/components/sql/SQLEditor.js",
        "/ts/components/sql/SQLExecutor.js",
        "/ts/components/sql/SQLSnippet.js",
        "/ts/components/sql/sqlQueryHistory.js",
        "/ts/components/sql/workspace/SQLEditorSpace.js",
        "/ts/components/sql/workspace/SQLHistorySpace.js",
        "/ts/components/sql/workspace/SQLResultSpace.js",
        "/ts/components/sql/workspace/SQLTable.js",
        "/ts/components/sql/workspace/SQLTableLister.js",
        "/ts/components/sql/workspace/SQLTableSchema.js",
        "/ts/components/sql/workspace/SQLWorkSpace.js"]}


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
        super().__init__(jenkins_artifacts=self.artifacts, add_branch_info=True)
        # XXXrs - temporary initialize every time with static configuration.
        #         Eventually, this configuration sould be managed elsewhere.
        self.reset_file_groups()
        for name, files in XDUnitTestArtifactsData.FILE_GROUPS.items():
            self.append_file_group(group_name=name, files=files)

    def update_build(self, *, bnum, log=None):
        """
        Return coverage info for a specific build.
        """
        try:
            path = os.path.join(self.artifacts.artifacts_directory_path(bnum=bnum),
                                self.coverage_file_name)
            self.logger.debug("path: {}".format(path))
            xdutc = XDUnitTestCoverage(path=path)
            data = {}
            for url,coverage in xdutc.get_data().items():
                self.logger.debug("url: {} coverage: {}".format(url, coverage))
                data[MongoDB.encode_key(url)] = coverage
            return {'coverage': data}
        except FileNotFoundError as e:
            self.logger.error("{} not found".format(path))
            return None

    def xd_versions(self):
        """
        Return available XD versions for which we have data.
        XXXrs - version/branch :|
        """
        return self.branches(repo='XD')

    def builds(self, *, xd_versions=None,
                        first_bnum=None,
                        last_bnum=None,
                        reverse=False):

        return self.find_builds(repo='XD',
                                branches=xd_versions,
                                first_bnum=first_bnum,
                                last_bnum=last_bnum,
                                reverse=reverse)

    def _get_coverage_data(self, *, bnum):
        data = self.get_data(bnum=bnum)
        if not data:
            return None
        return data.get('coverage', None)

    def filenames(self, *, bnum, group_name=None):
        coverage = self._get_coverage_data(bnum=bnum)
        if not coverage:
            return None

        rawnames = []
        do_sort = False
        if group_name is not None and group_name != "All Files":
            rawnames = self.expand(name=group_name)
        else:
            do_sort = True
            rawnames = sorted(coverage.keys())

        have_total = False
        # Reduce a URL to just a filename
        filenames = []
        for key in rawnames:
            url = MongoDB.decode_key(key)
            if url == 'Total':
                have_total = True
                continue
            fields = url.split('/')
            if len(fields) < 2:
                raise Exception("Incomprehensible: {}".format(url))
            filename = "{}/{}".format(fields[-2], fields[-1])
            if filename in filenames:
                raise Exception("Duplicate: {}".format(filename))
            filenames.append(filename)
        if do_sort:
            filenames.sort()
        if have_total:
            filenames.insert(0, "Total")
        return filenames

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
    print("Names: {}".format(data.file_group_names()))
    print("Groups: {}".format(data.file_groups()))

    """
    for version in data.xd_versions():
        print("{} ==========".format(version))
        builds = data.builds(xd_versions=[version])
        print(builds)
        for bnum in builds:
            print("{} ----------".format(bnum))
            for filename in data.filenames(bnum=bnum):
                print("{}: {}".format(filename, data.coverage(bnum=bnum, filename=filename)))

    print("let update thread run a little...")
    data.start_update_thread()
    import time
    time.sleep(30)
    print("stop update thread")
    data.stop_update_thread()
    print("DONE")
    """

    """
    XXXrs - The following "utility" code was used to pre-populate the git_branches.txt file
            for builds that didn't have them, using the "old" method of scraping the jenkins
            log and using git_helper() to find the branches containing the discovered
            commit sha(s).

    from py_common.git_helper import GitHelper
    from py_common.jenkins_api import JenkinsApi

    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    art = XDUnitTestArtifacts()
    japi = JenkinsApi()
    ghelp = GitHelper()
    data = XDUnitTestArtifactsData(artifacts = art)
    repo_pat = re.compile(r"\A(.*)_GIT_REPOSITORY\Z")

    for bnum in art.builds():
        log = japi.console(job_name='XCEFuncTest', build_number=bnum)
        adp = art.artifacts_directory_path(bnum=bnum)
        txt_path = os.path.join(adp, 'git_branches.txt')
        commits = ghelp.commits(log=log)
        txt = ""
        for commit, info in commits.items():
            repo = info.get('repo', None)
            if not repo:
                continue
            repo = repo_pat.match(repo).group(1)
            branches = info['branches']
            for branch in branches:
                if len(txt):
                    txt += "\n"
                txt += "{}_GIT_BRANCH: {}".format(repo, branch)
        if os.path.exists(txt_path):
            print("{} exists, skip...".format(txt_path))
            continue
        print("write {}".format(txt_path))
        with open(txt_path, "w+") as fh:
            fh.write(txt)
    """
