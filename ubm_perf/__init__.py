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
import statistics
import time

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_aggregators import JenkinsAggregatorBase
from py_common.jenkins_aggregators import JenkinsPostprocessorBase
from py_common.jenkins_aggregators import JenkinsJobDataCollection
from py_common.jenkins_aggregators import JenkinsJobMetaCollection
from py_common.jenkins_aggregators import JenkinsAlert
from py_common.jenkins_aggregators import JenkinsAllJobIndex
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

# XXX: In future, UbmTestGroupName could be an env var and in general needs
# to be made extensible (e.g. it should be easier to add more test groups)
UbmTestGroupName = "ubmTest"

# Number of prior runs, over which to calculate stats to decide if the current
# build has regressed or not
UbmNumPrevRuns = 3

# Regression detection threshold - number of std-deviations difference between
# historical and current mean times:
# i.e. for any benchmark,
#  if new_mean >= RegDetThr * historical_old_mean
#      then new_mean is flagged as having regressed
#  where historical_old_mean is the mean over the prior UbmNumPrevRuns runs
RegDetThr = 2


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


# Post-processor for Ubm called after each build/run (via update_job method)
# NOTE: test_mode is ignored. For now, the ubm module's update_job checks
# for regression and alerts if a regression is detected, besides computing
# stats over different historical periods. See comments above the update_job()
# method for details.
#
# The mean time reported for a ubm in the current build/run, is considered a
# regression if it exceeds the mean of the previous UbmNumPrevRuns runs or the
# mean of the oldest recorded UbmNumPrevRuns, by RegDetThr std deviations.
#
# More functionality may be added to update_job over time.

class UbmPerfPostprocessor(JenkinsPostprocessorBase):
    ENV_PARAMS = {"JENKINS_HOST": {'default': 'jenkins.int.xcalar.com'}}

    def __init__(self, *, job_name):
        pp_name = "{}_postprocessor".format(UbmTestGroupName)
        super().__init__(name=pp_name, job_name=job_name)
        self.logger = logging.getLogger(__name__)
        self.jmdb = JenkinsMongoDB()
        self.ubm_perf_results_data = UbmPerfResultsData()
        self.tgroups = self.ubm_perf_results_data.test_groups()
        # XXX: Restrict To address for now, replace with the appropriate
        # email alias, when confident of results
        self.jalert = JenkinsAlert(to_address="dshah@xcalar.com")
        cfg = EnvConfiguration(UbmPerfPostprocessor.ENV_PARAMS)
        self.urlprefix = "https://{}/job/{}/".format(cfg.get('JENKINS_HOST'),
                                                     self.job_name)
        self.alert_template =\
            "Regression(s) detected in following XCE benchmarks:\n{}\n\n" \
            "Please see console output at {} for more details"
        self.alert_email_subject = "Regression in XCE benchmarks!!"
        self.alljob = JenkinsAllJobIndex(jmdb=self.jmdb)

    # Given a test_group and data from several builds for this test_group,
    # return a nested dict with outer key=ubm and value=inner dict with the
    # inner dict having 3 keys:
    #
    #     build_cnt (number of builds in which ubm was executed)
    #     avg_s (average time in secs for ubm duration over build_cnt runs)
    #     stdev (std deviation for ubm duration over build_cnt runs)
    #
    def _ubm_stats(self, *, test_group, builds):
        self.logger.info("start")
        rtn = {}
        if not builds:
            # if there are no builds, return empty dict
            return rtn
        # first, for each ubm, collect a list of ubm mean durations
        # each element in the list corresponds to runs in a single build
        ubm_val_list = {}
        for bld in builds:
            b_job_name = bld.get('job_name', None)
            if not b_job_name or b_job_name != self.job_name:
                continue
            result = bld.get('result', None)
            if not result or result != 'SUCCESS':
                continue
            bnum = bld.get('build_number')
            ubm_vals = self.ubm_perf_results_data\
                .results(test_group=test_group, bnum=bnum)['ubm_vals']
            for ubm in ubm_vals:
                ubm_mean = statistics.mean(ubm_vals[ubm])
                ubm_val_list.setdefault(ubm, []).append(ubm_mean)
        # second, for each ubm, generate the count, mean, stdev stats across
        # all its elements (builds) in ubm_val_list and store in the rtn dict
        for ubm in ubm_val_list:
            self.logger.debug("ubm {} val_list {}".format(ubm,
                                                          ubm_val_list[ubm]))
            rtn.setdefault(ubm, {})['build_cnt'] = len(ubm_val_list[ubm])
            rtn.setdefault(ubm, {})['avg_s'] =\
                statistics.mean(ubm_val_list[ubm])
            if len(ubm_val_list[ubm]) > 1:
                rtn.setdefault(ubm, {})['stdev'] =\
                    statistics.stdev(ubm_val_list[ubm])
        return rtn

    # 'update_job' has two main goals:
    # (A) Flag a regression in latest run's stats vs historical stats
    # (B) Re-compute several periods' historical stats with the latest build's
    #     stats, and return this history as a dict (so that it can be stored
    #     in the mongo db)
    def update_job(self, *, test_mode=False):
        self.logger.info("start postprocess for: {}".format(self.job_name))

        if self.tgroups is None:
            return {}
        # XXX: currently, only one tg (== UbmTestGroupName) supported
        assert(len(self.tgroups) <= 1)
        for tg in self.tgroups:
            # for each test group, calculate stats for each ubm over the
            # previous UbmNumPrevRuns runs, to check if latest run has
            # regressed as compared to the immediately previous
            # UbmNumPrevRuns runs
            assert(tg == UbmTestGroupName)
            xcevs = self.ubm_perf_results_data.xce_versions(test_group=tg)
            builds = self.ubm_perf_results_data.\
                find_builds(test_group=tg, xce_versions=xcevs,
                            reverse=False)
            num_builds = len(builds)
            self.logger.debug("builds {}".format(builds))
            # if there aren't sufficient old builds to compare against,
            # return; else proceed to detect regression if any
            if num_builds - 1 < UbmNumPrevRuns:
                return {}

            # calculate avg over last UbmNumPrevRuns runs; first get the
            # begin/end offsets into the builds list for these builds
            begin_build_offset = num_builds - UbmNumPrevRuns - 1
            end_build_offset = begin_build_offset + UbmNumPrevRuns
            curr_bnum = builds[num_builds - 1]

            # convert list of last UbmNumPrevRuns builds into list of dicts
            # with job_name and build_number - to make this compatible with
            # the 'builds' param needed by _ubm_stats()
            prev_N_builds = []
            for b in builds[begin_build_offset:end_build_offset]:
                bdict = {'job_name': self.job_name, "build_number": b}
                prev_N_builds.append(bdict)

            ubm_prevNstats = self._ubm_stats(test_group=tg,
                                             builds=prev_N_builds)

            self.logger.debug("ubm_prevNstats -> {}".format(ubm_prevNstats))

            # Now get the latest ubm data for build curr_bnum
            curr_results = self.ubm_perf_results_data.results(
                test_group=tg, bnum=curr_bnum)
            curr_ubmvals = curr_results['ubm_vals']

            # For each ubm, check if there's a regression as compared to the
            # most recent UbmNumPrevRuns builds, building up a dictionary of
            # regressions in 'ubm_prevN_regr'
            ubm_prevN_regr = {}
            new_mean = {}
            for ubm in curr_ubmvals:
                new_mean[ubm] = statistics.mean(curr_ubmvals[ubm])
                old_mean = ubm_prevNstats[ubm]['avg_s']
                old_sdev = ubm_prevNstats[ubm].get('stdev')
                if old_sdev is not None and new_mean[ubm] >= old_mean +\
                   RegDetThr * old_sdev:
                    # There's a regression! Add the stats to regressions dict
                    # An alert will be sent about this after checking for
                    # oldest N window for regressions to prevent creeping
                    # regression over a long time
                    ubm_prevN_regr[ubm] = {}
                    ubm_prevN_regr[ubm]['old_mean'] = old_mean
                    ubm_prevN_regr[ubm]['old_stdev'] = old_sdev
                    ubm_prevN_regr[ubm]['new_times'] = curr_ubmvals[ubm]
                    ubm_prevN_regr[ubm]['new_mean'] = new_mean[ubm]

            # Now, compute per-period, per-ubm stats for 7 different periods
            # in the past - so the trends in a ubm's stats over time can be
            # inspected. In addition, check the latest stat against the oldest
            # window of N runs ('N_prev_30d' period) for regression - to flag
            # a creeping regression over time.
            #
            # Details:
            # Use self.alljob.builds_by_time() to get all builds within
            # a time period, and then invoke _ubm_stats() on the builds list
            # to get a ubm's stats (build_cnt, avg, stdev) over these builds

            ubm_all_period_stats = {}  # ubm all period (ap) stats dict
            try:
                day_ms = 3600000 * 24
                now = int(time.time()*1000)
                periods = [{'label': 'last_24h', 'start': now-day_ms, 'end': now},
                           {'label': 'prev_24h', 'start': now-(day_ms*2), 'end': now-day_ms-1},
                           {'label': 'last_7d', 'start': now-(day_ms*7), 'end':now  },
                           {'label': 'prev_7d', 'start': now-(day_ms*14), 'end': now-(day_ms*7)-1},
                           {'label': 'last_30d', 'start': now-(day_ms*30), 'end': now},
                           {'label': 'prev_30d', 'start': now-(day_ms*60), 'end': now-(day_ms*30)-1},
                           {'label': '{}_prev_30d'.format(UbmNumPrevRuns), 'start': now-(day_ms*60),
                            'end': now-(day_ms*(60-UbmNumPrevRuns))}]

                # for each period, compute per-ubm stats (as returned by
                # self._ubm_stats()) and store in ubm_all_period_stats dict,
                # prefixed by the period's label from the period dict above.
                # The ubm_all_period_stats{} dict will yield a dict with the
                # following layout as an example:
                # {
                #  "load": {
                #   "build_cnt": {
                #       "last_24h": 7,
                #       <period_label>: <build_cnt_for_period>
                #       ...
                #   },
                #   "avg_s": {
                #       "last_24h": 1472.7709387944287,
                #       <period_label>: <avg_s_for_period>
                #       ...
                #   },
                #   "stdev": {
                #       "last_24h": 15.04279609267221,
                #       <period_label>: <stdev_for_period>
                #       ...
                #   }
                #  },
                #  "sort": {
                #  },
                #  ...
                # }

                for period in periods:
                    self.logger.debug("period: {}".format(period))
                    builds = self.alljob.builds_by_time(
                        start_time_ms=period['start'],
                        end_time_ms=period['end'])
                    blist = builds.get('builds', None)
                    ubm_stats = self._ubm_stats(test_group=tg, builds=blist)
                    self.logger.debug("ubm_stats: {}".format(ubm_stats))
                    for ubm in ubm_stats:
                        for stat in ubm_stats[ubm]:
                            ubm_all_period_stats.setdefault(ubm, {}).\
                                setdefault(stat, {})[period['label']] =\
                                ubm_stats[ubm][stat]

                # now compute regression vs a N run group that's 60d old using
                # the ubm_all_period_stats{} dict to get this window
                oldest_Nrun_mean = ubm_all_period_stats[ubm]['avg_s'].\
                    get('N_prev_30d')
                oldest_Nrun_stdev = ubm_all_period_stats[ubm]['stdev'].\
                    get('N_prev_30d')

                # Check for regression against the oldest UbmNumPrevRuns
                # run, and accumulate into oldest_Nrun_regr if any found
                oldest_Nrun_regr = {}
                if oldest_Nrun_mean is not None and \
                   new_mean[ubm] >= oldest_Nrun_mean + \
                   RegDetThr * oldest_Nrun_stdev:
                    oldest_Nrun_regr[ubm] = {}
                    oldest_Nrun_regr[ubm]['oldest_mean'] = oldest_Nrun_mean
                    oldest_Nrun_regr[ubm]['oldest_stdev'] = oldest_Nrun_stdev
                    oldest_Nrun_regr[ubm]['new_times'] = curr_ubmvals[ubm]
                    oldest_Nrun_regr[ubm]['new_mean'] = new_mean[ubm]
            except Exception as e:
                self.logger.exception("update_job exception")
                return None

            # If the list of regressions is not empty, send an alert
            if len(ubm_prevN_regr) > 0 or len(oldest_Nrun_regr) > 0:
                recent_regr_key =\
                    'regr_over_{}_latest_runs'.format(UbmNumPrevRuns)
                old_regr_key =\
                    'regr_over_{}_oldest_runs'.format(UbmNumPrevRuns)
                ubm_prev_and_oldest_regr =\
                    {recent_regr_key: 'none',
                     old_regr_key: 'none'}

                if len(ubm_prevN_regr) > 0:
                    ubm_prev_and_oldest_regr[recent_regr_key] =\
                        ubm_prevN_regr
                if len(oldest_Nrun_regr) > 0:
                    ubm_prev_and_oldest_regr[old_regr_key] =\
                            oldest_Nrun_regr
                regs_json = json.dumps(ubm_prev_and_oldest_regr, indent=4)
                url = self.urlprefix + "{}".format(curr_bnum)
                alert_message = self.alert_template.format(
                        regs_json, url)
                self.logger.info(alert_message)
                self.jalert.send_alert(subject=self.alert_email_subject,
                                       body=alert_message)

            uaps_json = json.dumps(ubm_all_period_stats, indent=4)
            self.logger.debug("ubm_all_period_stats {}".format(uaps_json))
            return ubm_all_period_stats


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
