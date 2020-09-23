#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import datetime
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

def get_ts(*, dt, tm, tz):

    (year, month, day) = dt.split("-")
    (hour, minute, second) = tm.split(":")

    dt = tz.localize(datetime.datetime(int(year), int(month), int(day),
                                       int(hour), int(minute), int(second)))
    return dt.timestamp()

def ts_to_date_hour(*, ts):
    """
    Returns (<date_str>, <hr_str>)
        where <date_str> is "YYYY-MM-DD" and <hr_str> is "00" through "23"
    """
    dt = datetime.datetime.fromtimestamp(ts)
    return ("{}-{:02d}-{:02d}".format(dt.year, dt.month, dt.day), "{:02d}".format(dt.hour))

job_data_collections = {}
def get_job_data_collection(*, job_name):
    if job_name not in job_data_collections:
        job_data_collections[job_name] = JenkinsJobDataCollection(job_name=job_name, jmdb=JMDB)
    return job_data_collections[job_name]

def get_build_data(*, job_name, build_number):
    jdc = get_job_data_collection(job_name=job_name)
    return jdc.get_data(bnum=build_number)

def write_data(*, outdir, date, hour, data):
    os.makedirs(os.path.join(outdir, date), exist_ok=True)
    outfile = os.path.join(outdir, date, "{}.json".format(hour))
    logger.info("writing incremental: {}".format(outfile))
    with open(outfile, "w+") as fp:
        fp.write(json.dumps(data))

if __name__ == "__main__":

    import argparse
    import pytz

    argParser = argparse.ArgumentParser()
    argParser.add_argument('--outdir', required=True, type=str,
                                help='path to incrementals directory')

    argParser.add_argument('--prior_days', default=None, type=int,
                                help='defaults start_date to N days prior to today')
    argParser.add_argument('--start_ts', default=None, type=int,
                                help='start timestamp (s)')
    argParser.add_argument('--end_ts', default=None, type=int,
                                help='end timestamp (s)')

    argParser.add_argument('--start_date', default=None, type=str,
                                help='start date (YYYY-MM-DD) defaults to today')
    argParser.add_argument('--start_time', default=None, type=str,
                                help='start time (HH:MM:SS) defaults to 00:00:00')
    argParser.add_argument('--end_date', default=None, type=str,
                                help='end date (YYYY-MM-DD) defaults to start_date')
    argParser.add_argument('--end_time', default=None, type=str,
                                help='end time (HH:MM:SS) defaults to 23:59:59')
    argParser.add_argument('--tz', default="America/Los_Angeles", type=str,
                                help='timezone for inputs')
    args = argParser.parse_args()

    tz = pytz.timezone(args.tz)
    now = datetime.datetime.now(tz=tz)

    default_start_date = "{}-{}-{}".format(now.year, now.month, now.day)
    default_end_date = None

    if args.prior_days is not None:
        default_end_date = default_start_date
        prior = now-datetime.timedelta(days=args.prior_days)
        default_start_date = "{}-{}-{}".format(prior.year, prior.month, prior.day)

    start_ts = args.start_ts
    if not start_ts:
        start_dt = args.start_date
        if not start_dt:
            start_dt = default_start_date
        tm = args.start_time
        if not tm:
            tm = "00:00:00"
        start_ts = get_ts(dt=start_dt, tm=tm, tz=tz)

    end_ts = args.end_ts
    if not end_ts:
        end_dt = args.end_date
        if not end_dt:
            end_dt = default_end_date
        if not end_dt:
            # Same as start date then
            end_dt = start_dt
        tm = args.end_time
        if not tm:
            tm = "23:59:59"
        dt_str = "{} {}".format(end_dt, tm)
        end_ts = get_ts(dt=end_dt, tm=tm, tz=tz)

    logger.debug("start_ts: {}".format(start_ts))
    logger.debug(ts_to_date_hour(ts=start_ts))
    logger.debug("end_ts:   {}".format(end_ts))
    logger.debug(ts_to_date_hour(ts=end_ts))

    """
    Layout of output directory will be
    First level is date, each date has one file per hour...
        2020-08-27
            00.json
            01.json
            02.json
            ...
            23.json
        2020-08-28
            00.json
            01.json
            ...
            23.json
        ...

    Note: the directory/file date/time are (always) in UTC!
    """


    delta_t = end_ts - start_ts
    now = datetime.datetime.now()

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

    # Sort the build list by start time:w

    cur_date = None
    cur_hour = None
    cur_data = {}
    flush = False

    for binfo in sorted(blist, key=lambda d: d['start_time_ms']):
        ts_ms = binfo.get('start_time_ms', None)
        if not ts_ms:
            continue

        date, hour = ts_to_date_hour(ts=ts_ms/1000)

        if not cur_date:
            cur_date = date
        elif date != cur_date:
            flush = True

        if not cur_hour:
            cur_hour = hour
        elif hour != cur_hour:
            flush = True

        if flush:
            write_data(outdir=args.outdir,
                       date=cur_date,
                       hour=cur_hour,
                       data=cur_data)
            cur_date = date
            cur_hour = hour
            cur_data = {}
            flush = False

        job_name = binfo.pop('job_name')
        build_number = binfo.pop('build_number')
        build_data = get_build_data(job_name=job_name, build_number=build_number)
        cur_data.setdefault(job_name, {})[build_number] = build_data

    if cur_data:
        write_data(outdir=args.outdir,
                   date=cur_date,
                   hour=cur_hour,
                   data=cur_data)
