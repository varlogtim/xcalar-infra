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
import os
import re

from py_common.mongo import MongoDB
from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_artifacts import JenkinsArtifacts, JenkinsArtifactsData
from py_common.sorts import nat_sort

from coverage.file_groups import FileGroupsMixin

class ClangCoverageFilenameCollision(Exception):
    pass

class ClangCoverage(object):

    #ENV_PARAMS = {} # Placeholder
    GZIPPED = re.compile(r".*\.gz\Z")
                                                  
    def __init__(self, *, path):
        self.logger = logging.getLogger(__name__)
        #cfg = EnvConfiguration(ClangCoverage.ENV_PARAMS)
        self.path = path
        self.coverage_data = self._load_json()

    def _load_json(self):
        path = self.path
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

    def file_summaries(self):
        """
        Strip a full coverage results file down to just per-file summary data.
        Returns dictionary:
            {<file_path>: {<file_summary_data>},
             <file_path>: {<file_summary_data>},
             ...
             "totals": {<total_summary_data}}
        """
        summaries = {}
        if 'data' not in self.coverage_data:
            return summaries
        for info in self.coverage_data['data']:
            totals = info.get('totals', None)
            if totals:
                summaries['totals'] = totals
            for finfo in info['files']:
                filename = finfo.get('filename', None)
                if not filename:
                    continue # :|
                if filename in summaries:
                    raise ClangCoverageFilenameCollision(
                            "colliding file name: {}".format(filename))
                summaries[filename] = finfo.get('summary', None)
        return summaries


class XCEFuncTestArtifacts(JenkinsArtifacts):

    ENV_PARAMS = {"XCE_FUNC_TEST_JOB_NAME":
                        {"default": "XCEFuncTest",
                         "required":True},
                  "XCE_FUNC_TEST_ARTIFACTS_ROOT":
                        {"default": "/netstore/qa/coverage/XCEFuncTest",
                         "required":True} }

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(XCEFuncTestArtifacts.ENV_PARAMS)
        super().__init__(job_name=cfg.get("XCE_FUNC_TEST_JOB_NAME"),
                         dir_path=cfg.get("XCE_FUNC_TEST_ARTIFACTS_ROOT"))


class XCEFuncTestArtifactsData(FileGroupsMixin, JenkinsArtifactsData):

    # XXXrs - temporary static config.
    FILE_GROUPS = {"Critical Files": ["liboperators/GlobalOperators.cpp",
                                      "liboperators/LocalOperators.cpp",
                                      "liboperators/XcalarEval.cpp",
                                      "liboptimizer/Optimizer.cpp",
                                      "libxdb/Xdb.cpp",
                                      "libruntime/Runtime.cpp",
                                      "libquerymanager/QueryManager.cpp",
                                      "libqueryeval/QueryEvaluate.cpp",
                                      "libmsg/TwoPcFuncDefs.cpp"]}

    ENV_PARAMS = {"XCE_FUNC_TEST_COVERAGE_FILE_NAME":
                        {"default": "coverage.json",
                         "required": True}}
                  
    def __init__(self, *, artifacts):
        """
        Initializer.
    
        Required parameters:
            artifacts:  XCEFuncTestArtifacts instance
        """
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(XCEFuncTestArtifactsData.ENV_PARAMS)
        self.cvg_file_name = cfg.get("XCE_FUNC_TEST_COVERAGE_FILE_NAME")
        self.artifacts = artifacts
        super().__init__(jenkins_artifacts=self.artifacts, add_branch_info=True)
        # XXXrs - temporary initialize every time with static configuration.
        #         Eventually, this configuration sould be managed elsewhere.
        self.reset_file_groups()
        for name, files in XCEFuncTestArtifactsData.FILE_GROUPS.items():
            self.append_file_group(group_name=name, files=files)

    def update_build(self, *, bnum, log=None):
        """
        Read the coverage.json file and convert to our preferred index form,
        filtering for only files of interest (plus totals).
        """
        coverage_file_path = os.path.join(self.artifacts.artifacts_directory_path(bnum=bnum),
                                          self.cvg_file_name)
        try:
            summaries = ClangCoverage(path=coverage_file_path).file_summaries()
        except FileNotFoundError:
            return None

        data = {}
        for filename, summary in summaries.items():
            data.setdefault('coverage', {})[MongoDB.encode_key(filename)] = summary
        return data

    def xce_versions(self):
        """
        Return available XCE versions for which we have data.
        XXXrs - version/branch :|
        """
        return self.branches(repo='XCE')

    def builds(self, *, xce_versions=None,
                        first_bnum=None,
                        last_bnum=None,
                        reverse=False):

        return self.find_builds(repo='XCE',
                                branches=xce_versions,
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
        if group_name is not None and group_name != "All Files":
            rawnames = self.expand(name=group_name)
        else:
            # Load all file names available in coverage
            rawnames = sorted(coverage.keys())

        # Reduce to just final two path components
        filenames = []
        for key in rawnames:
            name = MongoDB.decode_key(key)
            if name == 'totals':
                # Skip this.
                continue
            fields = name.split('/')
            if len(fields) < 2:
                raise Exception("Incomprehensible: {}".format(name))
            filename = "{}/{}".format(fields[-2], fields[-1])
            if filename in filenames:
                raise Exception("Duplicate: {}".format(filename))
            filenames.append(filename)
        return filenames

    def coverage(self, *, bnum, filename):
        """
        XXXrs - FUTURE - extend to return other than "lines" percentage.
        """
        if filename == "Overall Total":
            filename = "totals"
        coverage = self._get_coverage_data(bnum=bnum)
        if not coverage:
            return None
        for key,data in coverage.items():
            name = MongoDB.decode_key(key)
            if filename in name:
                return coverage[key].get('lines', {}).get('percent', None)
        return None

if __name__ == '__main__':
    print("Compile check A-OK!")

    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    art = XCEFuncTestArtifacts()
    data = XCEFuncTestArtifactsData(artifacts = art)
    print("Names: {}".format(data.file_group_names()))
    print("Groups: {}".format(data.file_groups()))

    """
    data.start_update_thread()
    print("TRUNK builds ==========")
    print(data.builds(xce_versions=['trunk']))
    print("TRUNK filenames ==========")
    files = data.filenames(bnum="20083")
    for name in files:
        print("{}: {}".format(name, data.coverage(bnum="20083", filename=name)))
    print("2.0 ==========")
    print(data.builds(xce_versions=['xcalar-2.0.0']))
    for name in files:
        print("{}: {}".format(name, data.coverage(bnum=20083, filename=name)))
    import time
    time.sleep(600)
    data.stop_update_thread()
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

    art = XCEFuncTestArtifacts()
    japi = JenkinsApi()
    ghelp = GitHelper()
    data = XCEFuncTestArtifactsData(artifacts = art)
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
        #if os.path.exists(txt_path):
            #print("{} exists, skip...")
            #continue
        print("write {}".format(txt_path))
        with open(txt_path, "w+") as fh:
            fh.write(txt)
    """
