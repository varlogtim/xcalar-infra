#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

from datetime import datetime
import hashlib
import json
import logging
import os
import pytz
import re
import sys

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_aggregators import JenkinsAggregatorBase
from py_common.jenkins_aggregators import JenkinsJobDataCollection
from py_common.jenkins_aggregators import JenkinsJobMetaCollection
from py_common.jenkins_aggregators import JenkinsAggregatorDataUpdateTemporaryError
from py_common.mongo import MongoDB
from py_common.sorts import nat_sort
from sql_stats import SqlStats, SqlStatsIter, SqlNoStatsError

"""
XXXrs - WORKING HERE - How to deal with possible blended results under the same
        artifacts root.  Inspect parameters?  Completely separate job name?
        Punting for right now, and just proceeding as in original implementation.
"""

class SqlTpchStatsData(object):

    ENV_PARAMS = {"SQL_TPCH_JOB_NAME" : {"default": "SqlScaleTest"},
                  "SQL_TPCH_ARTIFACTS_ROOT": {"default": "/netstore/qa/jenkins/SqlScaleTest"} }

    result_file_pats = [re.compile(r"(.*)-(\d+)_tpchTest\.json\Z"),
                        re.compile(r"(.*)-(\d+)-xcalar_tpchTest\.json\Z")]

    def __init__(self):
        """
        Initializer

        Environment parameters:
            SQL_TPCH_JOB_NAME:  Jenkins job name.
            SQL_TPCH_RESULTS_ROOT:  Path to directory containing per-build sql tpch results.
        """
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(SqlTpchStatsData.ENV_PARAMS)
        self.job_name = cfg.get("SQL_TPCH_JOB_NAME")
        self.artifacts_root = cfg.get("SQL_TPCH_ARTIFACTS_ROOT")
        self.db = MongoDB()
        self.data = JenkinsJobDataCollection(job_name=self.job_name, db=self.db)
        self.meta = JenkinsJobMetaCollection(job_name=self.job_name, db=self.db)
        self.stats_cache = {}

    def xlr_versions(self):
        # XXXrs - this may be obsolete since we should now have the
        #         GIT_BRANCH meta-data?!?
        """
        Return all Xcalar versions represented in the index.
        """
        versions = []
        for bnum,data in self.data.get_data_by_build().items():
            tpch = data.get('sql_tpch', None)
            if not tpch:
                continue
            v = tpch.get('xlr_version', None)
            if v and v not in versions:
                versions.append(v)
        return versions

    def find_builds(self, *, xlr_versions=None,
                             first_bnum=None,
                             last_bnum=None,
                             test_type=None,
                             start_ts_ms=None,
                             end_ts_ms=None,
                             reverse=False):
        """
        Return list of build numbers matching the given attributes.
        By default, list is sorted in ascending natural number order.

        Optional parameters:
            xlr_versions:   list of Xcalar versions
            first_bnum:     matching build number must be gte this value
            last_bnum:      matching build number must be lte this value
            test_type:      results for build must be of this test_type
            start_ts_ms:    matching build start time gte this value
            end_ts_ms:      matching build end time lte this value
            reverse:        if True, results will be sorted in decending order.
        """
        found = []
        for bnum,data in self.data.get_data_by_build().items():
            tpch = data.get('sql_tpch', None)
            if not tpch:
                # no results
                continue
            xlr_ver = tpch.get('xlr_version', None)
            if xlr_versions and (not xlr_ver or xlr_ver not in xlr_versions):
                self.logger.debug("xlr_version mismatch want {} build {} has {}"
                                  .format(xlr_versions, bnum, xlr_ver))
                continue
            if test_type and tpch['test_type'] != test_type:
                self.logger.debug("test_type mismatch want {} build {} has {}"
                                  .format(test_type, bnum, tpch['test_type']))
                continue
            if start_ts_ms and tpch['start_ts_ms'] < start_ts_ms:
                continue
            if end_ts_ms and tpch['end_ts_ms'] > end_ts_ms:
                continue
            if first_bnum and int(bnum) < int(first_bnum):
                continue
            if last_bnum and int(bnum) > int(last_bnum):
                continue
            found.append(bnum)
        return sorted(found, key=nat_sort, reverse=reverse)

    def stats(self, *, bnum):
        """
        Return a SqlStats instance containing all results for a
        specified build number.
        """
        if bnum not in self.stats_cache:
            try:
                dir_path = os.path.join(self.artifacts_root, bnum)
                # XXXrs patterns
                stats = SqlStats(bnum=bnum, dir_path=dir_path,
                                 result_file_pats=SqlTpchStatsData.result_file_pats)
            except SqlNoStatsError as e:
                stats = None
            self.stats_cache[bnum] = stats
        return self.stats_cache[bnum]


class SqlTpchStatsAggregator(JenkinsAggregatorBase):

    ENV_PARAMS = {"SQL_TPCH_RESULTS_ROOT": {"default": "/netstore/qa/jenkins/SqlScaleTest"}}


    def __init__(self, *, job_name):

        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(SqlTpchStatsAggregator.ENV_PARAMS)
        self.data = SqlTpchStatsData()
        super().__init__(job_name=job_name)

    def update_build(self, *, bnum, log=None):

        stats = self.data.stats(bnum=bnum)
        if not stats:
            return None
        return {"sql_tpch": {'start_ts_ms': stats.start_ts_ms,
                             'end_ts_ms': stats.end_ts_ms,
                             'test_type': stats.test_type,
                             'xlr_version': stats.xlr_version}}


# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")

    import time
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    data = SqlTpchStatsData()

    now_ms = datetime.now().timestamp()*1000
    week_ms = 7*24*60*60*1000
    last_week = data.find_builds(start_ts_ms=(now_ms-week_ms),
                                 end_ts_ms=now_ms)
    #logger.info("last week: {}".format([s.build_num for s in last_week]))
    logger.info("last week: {}".format(last_week))
    last_month = data.find_builds(start_ts_ms=(now_ms-(4*week_ms)),
                                  end_ts_ms=now_ms,
                                  reverse=True)
    #logger.info("last month: {}".format([s.build_num for s in last_month]))
    logger.info("last month: {}".format(last_month))

    for bnum in last_week:
        stats = art.stats(bnum = bnum)
        print(stats)
