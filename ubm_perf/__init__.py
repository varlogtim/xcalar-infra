#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

__all__ = []

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
from py_common.mongo import MongoDB, JenkinsMongoDB
from py_common.sorts import nat_sort

# Classes to support Grafana based visualization of XCE operators'
# micro-benchmark performance data (generated regularly by a Jenkins job
# per build) to help identify performance regressions in operators.
#
# XXX: These classes are similar to those in sql_perf/__init__.py and in the
# future, we may want to refactor the code between these two files

# NOTE: UBM stands for MicroBenchmark (U for Micro), and a "ubm" is a single
# micro-benchmark, whose name would be the name of the test/operator: e.g.
# a ubmname would be "load" or "index", etc.

# Default convention:
# Jenkins job name = UbmTest
# test group name = ubmTest

UbmTestGroupName = "ubmTest"


class UbmPerfIter(object):
    """
    Class representing a single test iteration file.
    """
    version_pat = re.compile(r".*\(version=\'xcalar-(.*?)-.*")

    def _utc_to_ts_ms(self, t_str):
        dt = datetime.strptime(t_str, "%Y-%m-%dT%H:%M:%S.%f")
        return int(dt.replace(tzinfo=pytz.utc).timestamp()*1000)

    def __init__(self, *, bnum, inum, path):
        """
        Initializer

        Required parameters:
            bnum:   Build number
            inum:   Iteration number
            path:   Path to iteration .json file
        """

        self.logger = logging.getLogger(__name__)

        self.bnum = bnum
        self.inum = inum
        self.dataByUbm = {}
        with open(path, 'r') as fh:
            self.data = json.load(fh)

        self.test_group = self.data.get('group', None)
        if not self.test_group:
            raise ValueError("no test group in data")

        self.notes = self.data.get('notes', None)
        if not self.notes:
            raise ValueError("no notes in data")

        self.results = self.data.get('results', None)
        if not self.results:
            raise ValueError("no results in data")

        for ubm in self.results:
            self.dataByUbm.setdefault(ubm['name'], []).append(ubm['time'])

        self.start_ts_ms = self._utc_to_ts_ms(self.data['startUTC'])
        self.end_ts_ms = self._utc_to_ts_ms(self.data['endUTC'])

        # Test type is an md5 hash of test parameters for easy identification
        # of like tests which can be sanely compared.
        print("ubm names {}".format(self.ubm_names()))
        hashstr = "{}{}{}".format(self.test_group, self.notes,
                                  ":".join(self.ubm_names()))
        self.test_type = hashlib.md5(hashstr.encode()).hexdigest()

    def ubm_names(self):
        """
        Return sorted list of available ubm names (e.g. "index", "load", etc.)
        """
        return sorted(self.dataByUbm.keys(), key=nat_sort)

    def _times_for_ubm(self, *, ubmname):
        """
        Get all times for named ubm.

        Parameters:
            ubmname:  Ubm name (e.g. "index", or "filter", etc.)

        Returns:
            List of values - each value is time taken for a run
        """
        return self.dataByUbm[ubmname]

    def ubm_vals(self):
        """
        Get all result values for all ubms:
            <ubm>:[<val>, <val>...]
            <ubm>:...

        """
        return self.dataByUbm

    # currently the csv methods are unused but in the future they could be
    # used to populate Xcalar tables instead of mongdo db collections
    @staticmethod
    def csv_headers():
        return "Build,TestGroup,Ubm,Iteration,StartTime,EndTime,XcalarUbmTime"

    def to_csv(self):
        """
        Return list of csv strings of iteration data.
        """
        lines = []
        for ubmname in self.ubm_names():
            for ubmTime in self._times_for_ubm(ubmname=ubmname):
                lines.append("{},{},{},{},{},{},{}"
                             .format(self.bnum,
                                     self.test_group,
                                     ubmname,
                                     self.inum,
                                     self.start_ts_ms,
                                     self.end_ts_ms,
                                     ubmTime))
        return lines

    def to_json(self):
        """
        Return "canonical" json format string.
        """
        raise Exception("Not implemented.")


class UbmTestNoResultsError(Exception):
    pass


class UbmPerfResults(object):
    """
    Class representing the collection of all test iterations associated
    with a particular build.
    """

    # N.B.: Second match group expected to be iteration number: e.g. there
    # may be two iterations with the file names:
    #     xce-ubm-test-0-ubm_results.json
    #     xce-ubm-test-1-ubm_results.json
    # the '0' and '1' in above are the iteration number - can be extracted
    # using the following RE
    file_pats = [re.compile(r"(.*)-(\d+)-ubm_results\.json\Z")]

    def __init__(self, *, bnum, dir_path):
        """
        Initializer

        Required parameters:
            bnum:       Build number
            dir_path:   Path to directory containing all iteration files.
        """
        self.logger = logging.getLogger(__name__)
        self.build_num = bnum
        self.logger.info("start bnum {} dir_path {}".format(bnum, dir_path))
        self.iters_by_group = {}

        if not os.path.exists(dir_path):
            raise UbmTestNoResultsError("directory does not exist: {}".
                                        format(dir_path))

        # Load each of the iteration files...
        for name in os.listdir(dir_path):
            path = os.path.join(dir_path, name)
            self.logger.debug("path: {}".format(path))
            m = None
            for pat in UbmPerfResults.file_pats:
                m = pat.match(name)
                if m:
                    break
            else:
                self.logger.debug("skipping: {}".format(path))
                continue
            try:
                # N.B.: Second match group expected to be iteration number
                inum = m.group(2)
                spi = UbmPerfIter(bnum=bnum, inum=inum, path=path)
                self.iters_by_group.setdefault(spi.test_group, {})[inum] = spi
            except Exception:
                self.logger.exception("error loading {}".format(path))
                continue

        if not self.iters_by_group.keys():
            raise UbmTestNoResultsError("no results found: {}".
                                        format(dir_path))

    def test_groups(self):
        return self.iters_by_group.keys()

    def to_csv(self):
        """
        Return "canonical" csv format string.

            Build,TestGroup,Ubm,Iteration,StartTime,EndTime,XcalarUbmTime
            456,ubmTest,index,0,1561496761798,1561496764172,34857
            457,ubmTest,load,0,1561496788738,1561496799737,32190
            ...
        """
        csv = [UbmPerfIter.csv_headers()]
        for tg, iters in self.iters_by_group.items():
            for i, obj in iters.items():
                csv.extend(obj.to_csv())
        return "\n".join(csv)

    def to_json(self):
        """
        Return "canonical" json format string.
        """
        raise Exception("Not implemented.")

    @staticmethod
    def metric_names():
        """
        Return list of available metric names.
        """
        return ['time']

    def ubm_vals(self, *, test_group):

        iters = self.iters_by_group.get(test_group, None)
        if not iters:
            return None
        results = {}
        for i, obj in iters.items():
            for q, l in obj.ubm_vals().items():
                results.setdefault(q, []).extend(l)
        return results

    def index_data(self):
        data = {}
        for tg in self.test_groups():
            iters = self.iters_by_group.get(tg, None)
            if not iters:
                continue

            iter_nums = sorted(iters.keys(), key=nat_sort)

            data[tg] = {'start_ts_ms': iters[iter_nums[0]].start_ts_ms,
                        'end_ts_ms': iters[iter_nums[0]].end_ts_ms,
                        # Assume the configuration is the same for all
                        # iterations...
                        'test_type': iters[iter_nums[0]].test_type,
                        'notes': iters[iter_nums[0]].notes,
                        'ubm_vals': self.ubm_vals(test_group=tg)}
        return data


class UbmPerfResultsAggregator(JenkinsAggregatorBase):

    ENV_PARAMS = {"UBM_PERF_ARTIFACTS_ROOT":
                  {"default": "/netstore/qa/jenkins"}}

    def __init__(self, *, job_name):

        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(UbmPerfResultsAggregator.ENV_PARAMS)
        self.artifacts_root = cfg.get('UBM_PERF_ARTIFACTS_ROOT')
        super().__init__(job_name=job_name)

    def update_build(self, *, bnum, jbi, log, test_mode=False):
        try:
            dir_path = os.path.join(self.artifacts_root, self.job_name, bnum)
            self.logger.debug("path is {}".format(dir_path))
            results = UbmPerfResults(bnum=bnum, dir_path=dir_path)
        except UbmTestNoResultsError:
            return None
        data = results.index_data()
        self.logger.debug("data is {}".format(data))

        atms = []
        atms.append(('{}_builds'.format(UbmTestGroupName), bnum))
        atms.append(('test_groups', '{}'.format(UbmTestGroupName)))

        xce_branch = jbi.git_branches().get('XCE', None)
        if xce_branch:
            data['xce_version'] = xce_branch
            builds_key_sfx = MongoDB.encode_key("XCE_{}_builds".
                                                format(xce_branch))
            atms.append(('{}_XCE_branches'.format(UbmTestGroupName),
                         xce_branch))
            atms.append(('{}_{}'.format(UbmTestGroupName, builds_key_sfx),
                        bnum))
        if atms:
            data['_add_to_meta_set'] = atms
        return data


class UbmPerfResultsData(object):

    ENV_PARAMS = {"UBM_PERF_JOB_NAME": {"default": "UbmPerfTest"}}

    def __init__(self):
        """
        Initializer

        Environment parameters:
            UBM_PERF_JOB_NAME:  Jenkins job name.
        """
        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(UbmPerfResultsData.ENV_PARAMS)
        self.job_name = cfg.get("UBM_PERF_JOB_NAME")
        jdb = JenkinsMongoDB().jenkins_db()
        self.data = JenkinsJobDataCollection(job_name=self.job_name, db=jdb)
        self.meta = JenkinsJobMetaCollection(job_name=self.job_name, db=jdb)
        self.results_cache = {}

    def test_groups(self):
        doc = self.meta.coll.find_one({'_id': 'test_groups'})
        if not doc:
            return None
        return doc.get('values')

    def xce_versions(self, *, test_group):
        """
        Return all Xcalar versions represented in the index.
        """
        key = "{}_XCE_branches".format(test_group)
        doc = self.meta.coll.find_one({'_id': key})
        return doc.get('values', None)

    def builds_for_version(self, *, test_group, xce_version):
        key = MongoDB.encode_key("{}_XCE_{}_builds".
                                 format(test_group, xce_version))
        doc = self.meta.coll.find_one({'_id': key})
        if not doc:
            return None
        return doc.get('values', None)

    def builds_for_type(self, *, test_group, test_type):
        builds = []
        pat = {'{}.test_type'.format(test_group): test_type}
        self.logger.info("XXX: pat: {}".format(pat))
        for doc in self.data.coll.find(pat, projection={'_id': 1}):
            builds.append(doc['_id'])
        self.logger.info("XXX: builds: {}".format(builds))
        return builds

    def find_builds(self, *, test_group,
                    xce_versions=None,
                    test_type=None,
                    first_bnum=None,
                    last_bnum=None,
                    reverse=False):
        """
        Return list of build numbers matching the given attributes.
        By default, list is sorted in ascending natural number order.

        Required parameter:
            test_group:     the test group

        Optional parameters:
            xce_versions:   list of Xcalar versions
            test_type:      results for build must be of this test_type
            first_bnum:     matching build number must be gte this value
            last_bnum:      matching build number must be lte this value
            reverse:        if True, results will be sorted in decending order.
        """

        self.logger.debug("start")
        found = set([])
        if xce_versions:
            for version in xce_versions:
                bfv = self.builds_for_version(test_group=test_group,
                                              xce_version=version)
                found = found.union(set(bfv))

        if test_type:
            self.logger.info("test_type: {}".format(test_type))
            for_type = self.builds_for_type(test_group=test_group,
                                            test_type=test_type)
            found = found.intersection(for_type)

        if not found:
            return []

        rtn = []
        if first_bnum or last_bnum:
            for bnum in found:
                if first_bnum and int(bnum) < int(first_bnum):
                    continue
                if last_bnum and int(bnum) > int(last_bnum):
                    continue
                rtn.append(bnum)
        else:
            rtn = found

        rtn = sorted(rtn, key=nat_sort, reverse=reverse)
        self.logger.info("returning: {}".format(rtn))
        return rtn

    def results(self, *, test_group, bnum):
        cache_key = '{}:{}'.format(test_group, bnum)
        if cache_key in self.results_cache:
            return self.results_cache[cache_key]
        doc = self.data.get_data(bnum=bnum)
        data = {}
        if doc:
            data = doc.get(test_group, {})
        self.results_cache[cache_key] = data
        return data

    def test_type(self, *, test_group, bnum):
        try:
            data = self.results(test_group=test_group, bnum=bnum)
            return data['test_type']
        except Exception:
            self.logger.exception("exception finding test type")
            return None

    def config_params(self, *, test_group, bnum):
        try:
            data = self.results(test_group=test_group, bnum=bnum)
            return {'test_group': data.get('test_group'),
                    'notes': data.get('notes')}
        except Exception:
            self.logger.exception("exception finding config params")
            return {}

    def ubm_names(self, *, test_group, bnum):
        try:
            data = self.results(test_group=test_group, bnum=bnum)
            ubm_vals = data['ubm_vals']
            return sorted(ubm_vals.keys(), key=nat_sort)
        except Exception:
            self.logger.exception("exception finding ubm names")
            return []

    def ubm_vals(self, *, test_group, bnum, ubmname):
        try:
            data = self.results(test_group=test_group, bnum=bnum)
            return data['ubm_vals'][ubmname]
        except Exception:
            self.logger.exception("exception finding ubm values")
            return []


"""
# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")

    import time
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    data = UbmPerfData()

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
        results = data.results(bnum = bnum)
        print(results)

"""

# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")

    from pprint import pformat
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--bnum", help="build number", required=True)
    args = parser.parse_args()

    dir_path = os.path.join("/netstore/qa/jenkins/UbmPerfTest", args.bnum)

    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s -"
                        "%(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    results = UbmPerfResults(bnum=args.bnum, dir_path=dir_path)
    data = results.index_data()
    print(pformat(data))
    for ubm, vals in data['{}'.format(UbmTestGroupName)]['ubm_vals'].items():
        print("{}: {}".format(ubm, vals))
