#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

from datetime import datetime, timezone
import json
import logging
import os
import sys

sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_aggregators import JenkinsAllJobIndex
from py_common.jenkins_aggregators import JenkinsJobDataCollection
from py_common.mongo import JenkinsMongoDB

cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.WARNING},
                        'JENKINS_HOST': {'default': None},
                        'JENKINS_DB_NAME': {'default': None}})

# It's log, it's log... :)
logging.basicConfig(level=cfg.get('LOG_LEVEL'),
                    format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                    handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

JMDB = JenkinsMongoDB()
JENKINS_DB = JMDB.jenkins_db()

def ts_to_year_month(*, ts):
    """
    Returns (<year>, <month>)
        where <year> is four-digit year and <month> is "00" through "12"
    """
    dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    return ("{}".format(dt.year), "{:02d}".format(dt.month))

job_data_collections = {}
def get_job_data_collection(*, job_name):
    if job_name not in job_data_collections:
        job_data_collections[job_name] = JenkinsJobDataCollection(job_name=job_name,
                                                                  db=JENKINS_DB)
    return job_data_collections[job_name]

def write_data(*, outdir, year, month, data):
    for key,item in data.items():
        os.makedirs(os.path.join(outdir, year, month), exist_ok=True)
        outfile = os.path.join(outdir, year, month, "{}.json".format(key))
        logger.info("writing incremental: {}".format(outfile))
        with open(outfile, "w+") as fp:
            fp.write(json.dumps(item))

if __name__ == "__main__":

    import argparse
    import time
    from dateutil.relativedelta import relativedelta
    import pytz

    argParser = argparse.ArgumentParser()
    argParser.add_argument('--outdir', required=True, type=str,
                                help='path to incrementals directory')
    argParser.add_argument('--prior_months', default=0, type=int,
                                help='process for this many additional prior months')
    '''
    argParser.add_argument('--tz', default="America/Los_Angeles", type=str,
                                help='timezone for inputs')
    '''
    args = argParser.parse_args()

    '''
    tz = pytz.timezone(args.tz)
    now = datetime.now(tz=tz)
    '''

    now = datetime.now(timezone.utc)

    if args.prior_months > 0:
        prior = now-relativedelta(months=args.prior_months)
        start_year = prior.year
        start_month = prior.month
    else:
        start_year = now.year
        start_month = now.month

    # Midnight, first day of the start month/year
    start = datetime(start_year, start_month, 1, hour=0, minute=0, second=0, tzinfo=timezone.utc)
    logger.debug("start: {}".format(start))
    start_ts = start.timestamp()
    logger.debug("start_ts: {}".format(start_ts))

    # End is now
    end = datetime(now.year, now.month, now.day, hour=now.hour, minute=now.minute, second=now.second, tzinfo=timezone.utc)
    logger.debug("end: {}".format(end))
    end_ts = end.timestamp()
    logger.debug("end_ts: {}".format(end_ts))

    """
    Layout of output directory will be:
        /some/root/<year>/<month>/<data_type>.json

        <data_type> is:
            - builds - basic per-build data
            - tpchTest - TPC-H test performance data
            - functest_subtests - Functional test sub-test data
            - and so on...

        Data in all files are keyed by job_name and build_number.
    """

    """
    Use the start/end time to query for the list of completed builds.
    Each entry looks like:

        {'build_number': '3734',
         'built_on': 'jenkins-slave-el7-n12-1',
         'duration_ms': 67,
         'job_name': 'PrecheckinVerifyTrigger',
         'result': 'SUCCESS',
         'start_time_ms': 1599249540937}

    """
    alljob = JenkinsAllJobIndex(jmdb=JMDB)
    builds = alljob.builds_by_time(
                        start_time_ms=(start_ts*1000),
                        end_time_ms=(end_ts*1000))
    blist = builds.get('builds', None)
    if not blist:
        logger.info("No builds in time period")
        sys.exit(0)
    logger.info("Processing {} builds".format(len(blist)))

    # sub-blocks to extract from build data if they exist

    sub_blocks = ['functest_subtests',
                  'pytest_subtests',
                  'test_jdbc_subtests',
                  'xc_test_harness_subtests',
                  'tpchTest',
                  'tpcdsTest',
                  'coverage'] # XXXrs coverage takes different forms...

    cur_year = None
    cur_month = None
    cur_data = {}
    flush = False

    # Sort the build list by start time
    for binfo in sorted(blist, key=lambda d: d['start_time_ms']):
        ts_ms = binfo.get('start_time_ms', None)
        if not ts_ms:
            continue

        year, month = ts_to_year_month(ts=ts_ms/1000)

        if not cur_year:
            cur_year = year
        flush = year != cur_year

        if not cur_month:
            cur_month = month
        flush = month != cur_month

        if flush and cur_data:
            write_data(outdir=args.outdir,
                       year=cur_year,
                       month=cur_month,
                       data=cur_data)
            cur_year = year
            cur_month = month
            cur_data = {}
            flush = False

        job_name = binfo.pop('job_name')
        jdc = get_job_data_collection(job_name=job_name)
        build_number = binfo.pop('build_number')
        build_data = jdc.get_data(bnum=build_number)

        for sub in sub_blocks:
            if sub in build_data:
                cur_data.setdefault(sub, {}).setdefault(job_name, {})[build_number] = build_data.pop(sub)
        cur_data.setdefault('builds', {}).setdefault(job_name, {})[build_number] = build_data

    if cur_data:
        write_data(outdir=args.outdir,
                   year=cur_year,
                   month=cur_month,
                   data=cur_data)
