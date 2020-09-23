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

AGGREGATOR_PLUGINS = [{'class_name': 'CoreAnalyzerLogParser',
                       'job_names': ['__ALL__']}]


class CoreAnalyzerLogParserException(Exception):
    pass


class CoreAnalyzerLogParser(JenkinsAggregatorBase):
    def __init__(self, *, job_name):
        """
        Class-specific initialization.
        """
        super().__init__(job_name=job_name,
                         agg_name=self.__class__.__name__,
                         send_log_to_update=True)
        self.logger = logging.getLogger(__name__)


    def _do_update_build(self, *, bnum, jbi, log, test_mode=False):
        """
        Parse the log for analyzed core information
        """
        self.start_time_ms = jbi.start_time_ms()
        self.duration_ms = jbi.duration_ms()

        cores = {}
        cur_core = None

        for lnum, line in enumerate(log.splitlines()):

            fields = line.split()
            if len(fields) < 4:
                continue

            # 2847.711 #### Analyzing buildOut/src/bin/usrnode/usrnode core.usrnode.7703 #####
            if '####' in fields[1] and fields[2] == 'Analyzing':
                if cur_core is not None:
                    raise CoreAnalyzerLogParserException(
                            "Analysis header before analysis footer {}"
                            .format(lnum, line))

                cur_core = {'bin_path': fields[3], 'corefile_name': fields[4]}
                continue

            # 2847.730 Core was generated by `usrnode --nodeId 0 --numNodes 3 --configFile /home/jenkins/workspace/Controller'.
            if cur_core is not None and "Core was generated by" in line:
                cur_core['gen_by'] = " ".join(fields[5:])
                continue

            # 2847.882 Program terminated with signal SIGSEGV, Segmentation fault.
            if cur_core is not None and "Program terminated with" in line:
                cur_core['term_with'] = " ".join(fields[4:])
                continue

            # 2848.003 #### Done with buildOut/src/bin/usrnode/usrnode core.usrnode.7703 #####
            if '####' in fields[1] and fields[2] == 'Done' and fields[3] == 'with':
                if cur_core is None:
                    raise CoreAnalyzerLogParserException(
                            "Analysis footer before analysis header {} {}"
                            .format(lnum, line))

                if fields[4] != cur_core['bin_path']:
                    raise CoreAnalyzerLogParserException(
                            "Mismatch bin_path {} {} expected {}"
                            .format(lnum, line, cur_core['bin_path']))

                if fields[5] != cur_core['corefile_name']:
                    raise CoreAnalyzerLogParserException(
                            "Mismatch corefile_name {} {} expected {}"
                            .format(lnum, line, cur_core['corefile_name']))
                key = cur_core.pop('corefile_name')
                cores[key] = cur_core
                cur_core = None
                continue

        return {'analyzed_cores': cores}


    def update_build(self, *, bnum, jbi, log, test_mode=False):
        try:
            return self._do_update_build(bnum=bnum, jbi=jbi, log=log, test_mode=test_mode)
        except:
            self.logger.error("TEST PARSE ERROR")
            raise


# In-line "unit test"
if __name__ == '__main__':
    import argparse
    from pprint import pprint, pformat
    from py_common.jenkins_api import JenkinsApi, JenkinsBuildInfo

    # It's log, it's log... :)
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler(sys.stdout)])

    parser = argparse.ArgumentParser()
    parser.add_argument("--job", help="jenkins job name", default="ControllerTest")
    parser.add_argument("--bnum", help="jenkins build number", default="306")
    parser.add_argument("--log", help="just print out the log", action="store_true")
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
        parser = CoreAnalyzerLogParser(job_name=job_name)
        jbi = JenkinsBuildInfo(job_name=job_name, build_number=build_number, japi=japi)
        log = jbi.console()
        result = jbi.result()
        if args.log:
            print(log)
        else:
            print("checking job: {} build: {} result: {}".format(job_name, build_number, result))
            data = parser.update_build(bnum=build_number, jbi=jbi, log=jbi.console())
            pprint(data)
