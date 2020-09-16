#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import logging
import os
import sys

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.jenkins_aggregators import JenkinsAggregatorBase
from py_common.mongo import MongoDB

# The AGGREGATOR_PLUGINS list registers aggregator plug-in classes with Jenkins jobs.
# Each entry in the list is a dictionary of the form:
#
#   {'class': <class name>, 'job_names': [<jenkins job name>, ...]}

# XXXrs - Disabled pending further review ENG-9840
#AGGREGATOR_PLUGINS = [{'class_name': 'PyTestLogParser',
#                       'job_names': ['XCETest']}]

class PyTestLogParserException(Exception):
    pass

class PyTestLogParser(JenkinsAggregatorBase):
    def __init__(self, *, job_name):
        """
        Class-specific initialization.
        """
        super().__init__(job_name=job_name, send_log_to_update=True)
        self.logger = logging.getLogger(__name__)


    def update_build(self, *, bnum, jbi, log, test_mode=False):
        """
        Parse the log for sub-test info.
        """
        self.start_time_ms = jbi.start_time_ms()
        self.duration_ms = jbi.duration_ms()

        past_start_marker = False
        past_durations_marker = False
        subtest_data = {}
        for line in log.splitlines():
            '''
            3339.573  ============================= test session starts ==============================
            '''

            if not past_start_marker and "=== test session starts ===" in line:
                past_start_marker = True
                continue

            if not past_start_marker:
                continue

            '''
            5931.514  ========================== slowest 10 test durations ===========================
            '''
            if "test durations ======" in line:
                past_durations_marker = True
                continue

            fields = line.split()
            if len(fields) < 3:
                continue

            '''
            5931.515  = 279 passed, 190 skipped, 1 deselected, 4 xfailed, 3 warnings in 2591.94s (0:43:11) =
            '''
            if past_durations_marker and fields[1] == '=' and fields[-1] == '=':
                past_start_marker = False
                past_durations_marker = False
                continue

            '''
            5931.515  251.63s call     test_udf.py::TestUdf::testSharedUdfSanity
            5931.515  162.94s call     test_operators.py::TestOperators::testAddManyColumns
            '''
            if past_durations_marker:
                # duration parsing
                if fields[2] != "call":
                    continue

                duration_ms = int(float(fields[1][:-1])*1000)
                subtest_id = MongoDB.encode_key(fields[3])

                if subtest_id not in subtest_data:
                    self.logger.warn("subtest_id {} in durations but not seen before"
                                     .format(subtest_id))
                    continue
                subtest_data[subtest_id]['duration_ms'] = duration_ms

            # We're looking at test completion lines like:
            result = fields[2]
            if result not in ['PASSED', 'FAILED', 'SKIPPED', 'XFAIL']:
                continue

            """
            3352.142  test_export.py::TestExport::testCombinations[table0-Default-csv-createRule0-splitRule3-every] SKIPPED [  4%]
            7521.393  io/test_csv.py::test_csv_parser[Easy_sanity_test-schemaFile] XFAIL       [ 31%]
            7613.720  io/test_csv.py::test_csv_parser[zero_length_fields-loadInputWithHeader] PASSED [ 35%]
            3714.433  test_operators.py::TestOperators::testSelectNoRowsAggregate PASSED       [ 49%]
            10981.859  io/test_export.py::test_multiple_parquet_telecom_prefixed FAILED         [ 98%]
            """
            try:
                timestamp_ms = int(self.start_time_ms+(float(fields[0])*1000))
            except ValueError:
                self.logger.exception("timestamp parse error: {}".format(line))
                continue

            subtest_id = MongoDB.encode_key(fields[1])
            if subtest_id in subtest_data:
                raise PyTestLogParserException("duplicate subtest ID: {}".format(subtest_id))
            subtest_data[subtest_id] = {'name': fields[1],
                                        'result': fields[2],
                                        'end_time_ms': timestamp_ms}

            """
            NOTE FOR FUTURE

            Might care about these markers/signatures:

            11017.391  =================================== FAILURES ===================================
            11017.391  ____________________ test_multiple_parquet_telecom_prefixed ____________________
            11017.391
            ...SNIP...
            11017.400  ----------------------------- Captured stdout call -----------------------------
            ...SNIP...
            11017.400  ---------- coverage: platform linux, python 3.6.11-final-0 -----------
            ... yadda yadda ...
            """


        return {'pytest_subtests': subtest_data} # XXXrs can there be multiple in the same log?


# In-line "unit test"
if __name__ == '__main__':
    import argparse
    from pprint import pprint, pformat
    from py_common.jenkins_api import JenkinsApi, JenkinsBuildInfo

    # It's log, it's log... :)
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])


    parser = argparse.ArgumentParser()
    parser.add_argument("--job", help="jenkins job name", default="XCETest")
    parser.add_argument("--bnum", help="jenkins build number", default="49922")
    args = parser.parse_args()

    test_builds = []
    builds = args.bnum.split(':')
    if len(builds) == 1:
        test_builds.append((args.job, args.bnum))
    else:
        for bnum in range(int(builds[0]), int(builds[1])+1):
            test_builds.append((args.job, bnum))

    japi = JenkinsApi(host='jenkins.int.xcalar.com')

    for job_name,build_number in test_builds:
        parser = PyTestLogParser(job_name=job_name)
        jbi = JenkinsBuildInfo(job_name=job_name, build_number=build_number, japi=japi)
        result = jbi.result()
        print("checking job: {} build: {} result: {}".format(job_name, build_number, result))
        data = parser.update_build(bnum=build_number, jbi=jbi, log=jbi.console())
        pprint(data)
