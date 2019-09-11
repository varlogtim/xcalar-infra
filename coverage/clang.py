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
import sys

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.jenkins_aggregators import JenkinsAggregatorBase
from py_common.mongo import MongoDB

class ClangCoverageFilenameCollision(Exception):
    pass

class ClangCoverageEmptyFile(Exception):
    pass

class ClangCoverage(object):

    GZIPPED = re.compile(r".*\.gz\Z")

    def __init__(self, *, path):
        self.logger = logging.getLogger(__name__)
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

        jstr = ""
        if self.GZIPPED.match(path):
            with gzip.open(path, "rb") as fh:
                jstr = fh.read().decode("utf-8")
        else:
            with open(path, "r") as fh:
                jstr = fh.read()

        if not len(jstr):
            raise ClangCoverageEmptyFile("{} is empty".format(path))
        return json.loads(jstr)

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


class ClangCoverageAggregator(JenkinsAggregatorBase):

    def __init__(self, *, job_name,
                          coverage_file_name,
                          artifacts_root):

        self.logger = logging.getLogger(__name__)
        self.coverage_file_name = coverage_file_name
        self.artifacts_root = artifacts_root
        super().__init__(job_name=job_name)

    def update_build(self, *, bnum, jbi, log):
        """
        Read the coverage.json file and convert to our preferred index form,
        filtering for only files of interest (plus totals).
        """
        coverage_file_path = os.path.join(self.artifacts_root, bnum, self.coverage_file_name)
        try:
            summaries = ClangCoverage(path=coverage_file_path).file_summaries()
        except FileNotFoundError:
            self.logger.exception("file not found: {}".format(coverage_file_path))
            return None
        except ClangCoverageEmptyFile:
            self.logger.exception("file is empty: {}".format(coverage_file_path))
            return None
        except Exception:
            self.logger.exception("exception loading: {}".format(coverage_file_path))
            raise

        data = {}
        for filename, summary in summaries.items():
            data.setdefault('coverage', {})[MongoDB.encode_key(filename)] = summary
        return data


if __name__ == '__main__':
    print("Compile check A-OK!")
