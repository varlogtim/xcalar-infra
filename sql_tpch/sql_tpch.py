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

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_artifacts import JenkinsArtifacts, JenkinsArtifactsData
from py_common.sorts import nat_sort

class SqlTpchIter(object):
    """
    Class representing a single TPCH test iteration file.
    """
    version_pat = re.compile(r".*\(version=\'xcalar-(.*?)-.*")

    def _utc_to_ts_ms(self, t_str):
        dt = datetime.strptime(t_str, "%Y-%m-%dT%H:%M:%S.%f")
        return int(dt.replace(tzinfo=pytz.utc).timestamp()*1000)

    def __init__(self, *, bnum, iteration, path):
        """
        Initializer

        Required parameters:
            bnum:       Build number
            iteration:  Iteration number
            path:       Path to iteration .json file
        """

        self.logger = logging.getLogger(__name__)

        self.bnum = bnum
        self.iteration = iteration
        self.dataByQ = {}
        with open(path, 'r') as fh:
            self.data = json.load(fh)

        threads = self.data.get('threads', None)
        if not threads:
            raise ValueError("no threads in data")

        num_users = len(threads)
        notes = self.data.get('notes', None)
        if not notes:
            raise ValueError("no notes in data")

        ds = self.data.get('dataSource', None)
        if ds:
            ds = ds.get('dataSource', None)
        if not ds:
            raise ValueError("no dataSource in data")
        data_source = os.path.basename(os.path.abspath(ds))

        # XXXrs - screen scrape
        self.xlr_version = SqlTpchIter.version_pat.match(self.data['xlrVersion']).group(1) or 'unknown'

        for tnum, queryStats in self.data['threads'].items():
            self.logger.debug("tnum: {}, queryStats: {}".format(tnum, queryStats))
            for q in queryStats:
                self.logger.debug("q: {}".format(q))
                if isinstance(q, list):
                    self.dataByQ.setdefault(q[0]['qname'], []).append(q[0])
                else:
                    self.dataByQ.setdefault(q['qname'], []).append(q)

        self.start_ts_ms = self._utc_to_ts_ms(self.data['startUTC'])
        self.end_ts_ms = self._utc_to_ts_ms(self.data['endUTC'])

        # Test type is an md5 hash of test parameters for easy identification
        # of like tests which can be sanely compared.
        hashstr = "{}{}{}{}".format(num_users, notes, data_source, ":".join(self.query_names()))
        self.test_type = hashlib.md5(hashstr.encode()).hexdigest()

    def query_names(self):
        """
        Return sorted list of available query names (e.g. "q3")
        """
        return sorted(self.dataByQ.keys(), key=nat_sort)

    def _results_for_query(self, *, qname):
        """
        Get all results for named query.

        Parameters:
            qname:  Query name (e.g. "q11")

        Returns:
            List of dictionaries of the form:
                {'exe': <query exe time>,
                 'fetch': <query fetch time>}
        """
        results = []
        for q in self.dataByQ.get(qname, []):
            if 'xcalar' in q:
                qstart = q['xcalar']['queryStart']
                qend = q['xcalar']['queryEnd']
                fstart = q['xcalar']['fetchStart']
                fend = q['xcalar']['fetchEnd']
            else:
                qstart = q['qStart']
                qend = q['qEnd']
                fstart = q['fStart']
                fend = q['fEnd']
            results.append({'exe': qend-qstart,
                            'fetch': fend-fstart})
        return results

    @staticmethod
    def csv_headers():
        return "Build,Query,Iteration,StartTsMs,EndTsMs,XcalarQueryTime,XcalarFetchTime"

    def to_csv(self):
        """
        Return list of csv strings of iteration data.
        """
        lines = []
        for qname in self.query_names():
            for results in self._results_for_query(qname=qname):
                lines.append("{},{},{},{},{},{},{}"
                             .format(self.bnum,
                                     qname,
                                     self.iteration,
                                     self.start_ts_ms,
                                     self.end_ts_ms,
                                     results['exe'],
                                     results['fetch']))
        return lines

    def to_json(self):
        """
        Return "canonical" json format string.
        """
        raise Exception("Not implemented.")

    def query_vals(self, *, qname, mname):
        """
        Get result values for named query.

        Required parameters:
            qname:  Query name (e.g. 'q4')
            mname:  Metric name (e.g. 'exe_t')

        Returns:
            List of ms time values for requested query
            and metric.
        """
        results = []
        for r in self._results_for_query(qname=qname):
            if mname == 'exe_t':
                results.append(r['exe'])
            elif mname == 'fetch_t':
                results.append(r['fetch'])
            elif mname == 'total_t':
                results.append(r['exe']+r['fetch'])
            else:
                raise ValueError("unknown metric {}".format(mname))
        return results


class SqlTpchNoStatsError(Exception):
    pass


class SqlTpchStats(object):
    """
    Class representing the collection of all TPCH test iterations associated
    with a particular build (test run).
    """

    result_file_pat = re.compile(r"(.*)-(\d+)_tpchTest\.json\Z")
    result_file_pat_two = re.compile(r"(.*)-(\d+)-xcalar_tpchTest\.json\Z")

    @staticmethod
    def has_results(*, dir_path):
        for name in os.listdir(dir_path):
            if SqlTpchStats.result_file_pat.match(name) or SqlTpchStats.result_file_pat_two.match(name):
                return True
        return False

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
        self.iters = {}
        if not bnum:
            raise ValueError("no build number")
        if not dir_path:
            raise ValueError("no directory path")

        # Load each of the iteration files...

        for name in os.listdir(dir_path):
            path = os.path.join(dir_path, name)
            self.logger.debug("path: {}".format(path))
            m = SqlTpchStats.result_file_pat.match(name)
            if not m:
                m = SqlTpchStats.result_file_pat_two.match(name)
            if not m:
                self.logger.debug("skipping: {}".format(path))
                continue
            try:
                iteration = m.group(2)
                self.iters[iteration] = SqlTpchIter(bnum=bnum, iteration=iteration, path=path)
            except Exception as e:
                self.logger.exception("error loading {}".format(path))
                continue

        if self.iters.keys():
            iter_nos = sorted(self.iters.keys(), key=nat_sort)
            self.start_ts_ms = self.iters[iter_nos[0]].start_ts_ms
            self.end_ts_ms = self.iters[iter_nos[-1]].end_ts_ms
            self.test_type = self.iters[iter_nos[0]].test_type # XXXrs - assume all same
            self.xlr_version = self.iters[iter_nos[0]].xlr_version # XXXrs - assume all same
        else:
            raise SqlTpchNoStatsError("no results found: {}".format(dir_path))

        self.logger.debug("end")

    def to_csv(self):
        """
        Return "canonical" csv format string.

            Build,StartTsMs,EndTsMs,Query,XcalarQueryTimeMs,XcalarFetchTimeMs
            456,1561496761798,1561496764172,q6,34857,2702
            457,1561496788738,1561496799737,q6,32190,2113
            ...
        """
        csv = [SqlTpchIter.csv_headers()]
        for i,obj in self.iters.items():
            csv.extend(obj.to_csv())
        return "\n".join(csv)

    def to_json(self):
        """
        Return "canonical" json format string.
        """
        raise Exception("Not implemented.")

    def query_names(self):
        """
        Return sorted list of available query names (e.g. "q3")
        """
        names = None
        for i,obj in self.iters.items():
            if not names:
                names = obj.query_names()
                continue
            # All iterations are presumed to run the same set of
            # queries.  Validate this assumption.

            check_names = obj.query_names()
            if check_names != names:
                raise Exception("iteration {} query names {} don't match master set: {}"
                                .format(i, check_names, names))
        return names

    @staticmethod
    def metric_names():
        """
        Return list of available metric names.
        """
        return ['total_t', 'exe_t', 'fetch_t']

    def query_vals(self, *, qname, mname):
        times = []
        for i,obj in self.iters.items():
            times.extend(obj.query_vals(qname=qname, mname=mname))
        return times

class SqlTpchStatsArtifacts(JenkinsArtifacts):
    """
    Class representing directory containing sql tpch statistics results files.
    """

    ENV_PARAMS = {"SQL_TPCH_JOB_NAME": {"default": "SqlScaleTest"},
                  "SQL_TPCH_RESULTS_ROOT": {"default": "/netstore/qa/jenkins/SqlScaleTest"}}

    def __init__(self):
        """
        Initializer

        Environment parameters:
            SQL_TPCH_JOB_NAME:  Jenkins job name.
            SQL_TPCH_RESULTS_ROOT:  Path to directory containing per-build sql tpch results.
        """
        self.logger = logging.getLogger(__name__)
        self.cfg = EnvConfiguration(SqlTpchStatsArtifacts.ENV_PARAMS)
        super().__init__(job_name=self.cfg.get("SQL_TPCH_JOB_NAME"),
                         dir_path=self.cfg.get("SQL_TPCH_RESULTS_ROOT"))
        self.stats_cache = {}

    def stats(self, *, bnum):
        """
        Return a SqlTpchStats instance containing all results for a
        specified build number.
        """
        if bnum not in self.stats_cache:
            try:
                stats = SqlTpchStats(bnum=bnum, dir_path=self.artifacts_directory_path(bnum=bnum))
            except SqlTpchNoStatsError as e:
                stats = None
            self.stats_cache[bnum] = stats
        return self.stats_cache[bnum]


class SqlTpchStatsArtifactsData(JenkinsArtifactsData):
    """
    Class representing the meta-data associated with a
    specified SqlTpchStatsArtifacts.
    """
    def __init__(self, *, artifacts):
        """
        Initializer.

        Required parameters:
            artifacts:  SqlTpchStatsArtifacts instance
        """
        self.logger = logging.getLogger(__name__)
        self.artifacts = artifacts
        super().__init__(jenkins_artifacts=artifacts)

    def update_build(self, *, bnum, log=None):
        stats = self.artifacts.stats(bnum=bnum)
        if not stats:
            # Effectively a null entry indicating no stats available
            return {'start_ts_ms': 0, 'end_ts_ms': 0,
                    'test_type': None, 'xlr_version': None}

        return {'start_ts_ms': stats.start_ts_ms,
                'end_ts_ms': stats.end_ts_ms,
                'test_type': stats.test_type,
                'xlr_version': stats.xlr_version}

    def xlr_versions(self):
        """
        Return all Xcalar versions represented in the index.
        """
        versions = []
        for bnum,data in self.get_data_by_build().items():
            v = data.get('xlr_version', None)
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
        # XXXrs - FUTURE - this overrides the new base-class find_builds().
        #         Should merge with or leverage that code???
        found = []
        for bnum,data in self.get_data_by_build().items():
            if not data.get('start_ts_ms', None):
                # no results
                continue
            xlr_ver = data.get('xlr_version', None)
            if xlr_versions and (not xlr_ver or xlr_ver not in xlr_versions):
                self.logger.debug("xlr_version mismatch want {} build {} has {}"
                                  .format(xlr_versions, bnum, xlr_ver))
                continue
            if test_type and data['test_type'] != test_type:
                self.logger.debug("test_type mismatch want {} build {} has {}"
                                  .format(test_type, bnum, data['test_type']))
                continue
            if start_ts_ms and data['start_ts_ms'] < start_ts_ms:
                continue
            if end_ts_ms and data['end_ts_ms'] > end_ts_ms:
                continue
            if first_bnum and int(bnum) < int(first_bnum):
                continue
            if last_bnum and int(bnum) > int(last_bnum):
                continue
            found.append(bnum)
        return sorted(found, key=nat_sort, reverse=reverse)


# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")

    import time
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    art = SqlTpchStatsArtifacts()
    meta = SqlTpchStatsArtifactsData(artifacts = art)

    meta.start_update_thread()
    time.sleep(0.3)

    now_ms = datetime.now().timestamp()*1000
    week_ms = 7*24*60*60*1000
    last_week = meta.find_builds(start_ts_ms=(now_ms-week_ms),
                                 end_ts_ms=now_ms)
    #logger.info("last week: {}".format([s.build_num for s in last_week]))
    logger.info("last week: {}".format(last_week))
    last_month = meta.find_builds(start_ts_ms=(now_ms-(4*week_ms)),
                                  end_ts_ms=now_ms,
                                  reverse=True)
    #logger.info("last month: {}".format([s.build_num for s in last_month]))
    logger.info("last month: {}".format(last_month))

    for bnum in last_week:
        stats = art.stats(bnum = bnum)
        print(stats)

    time.sleep(60)
    meta.stop_update_thread()
