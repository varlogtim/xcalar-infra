#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

from abc import ABC, abstractmethod
import json
import logging
import os
from pymongo.errors import DuplicateKeyError
from pymongo import ReturnDocument
import re
import signal
import sys
import time

sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.mongo import MongoDB
from py_common.jenkins_aggregators import JenkinsJobDataCollection
from py_common.jenkins_aggregators import JenkinsJobMetaCollection
from py_common.jenkins_aggregators import JenkinsJobInfoAggregator
from py_common.jenkins_aggregators import JenkinsAggregatorDataUpdateTemporaryError
from py_common.jenkins_aggregators import Plugins
from py_common.jenkins_api import JenkinsApi
from py_common.mongo import MongoDBKeepAliveLock
from py_common.sorts import nat_sort


class JenkinsJobAggregators(object):
    """
    Controller class for set of aggregators for a job.
    Handles aggregator execution, storing of returned data, retries.
    """
    ENV_PARAMS = {'JENKINS_AGGREGATOR_UPDATE_BUILDS_MAX':
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 25},
                  'JENKINS_AGGREGATOR_UPDATE_FREQ_SEC':
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 300} }

    def __init__(self, *, job_name, db, additional=None):
        """
        Initializer.

        Required parameters:
            job_name:   Jenkins job name
            db:         MongoDB instance

        Optional parameters:
            additional: additional (custom) aggregator classes
        """
        self.logger = logging.getLogger(__name__)
        self.job_name = job_name
        self.additional = additional

        cfg = EnvConfiguration(JenkinsJobAggregators.ENV_PARAMS)
        self.builds_max = cfg.get('JENKINS_AGGREGATOR_UPDATE_BUILDS_MAX')

        # XXXrs - This is presently unused.  Want to stash the time of
        #         last update, and refuse to run again until sufficient
        #         time has passed.
        self.freq_sec = cfg.get('JENKINS_AGGREGATOR_UPDATE_FREQ_SEC')

        self.data_coll = JenkinsJobDataCollection(job_name=job_name, db=db)
        self.meta_coll = JenkinsJobMetaCollection(job_name=job_name, db=db)

        self.japi = JenkinsApi()

    def _update_build(self, *, bnum):
        """
        Call all aggregators on the build.  Consolidate results
        and store to the DB.  All or nothing.  All aggregators
        must run successfully or we bail and try again in the
        future (if allowed).
        """
        self.logger.info("process bnum: {}".format(bnum))
        # Already have a data entry?
        if self.data_coll.get_data(bnum=bnum) is not None:
            self.logger.debug("already seen, skipping...")
            return

        # Waiting for retry timeout?
        if self.meta_coll.retry_pending(bnum=bnum):
            self.logger.debug("retry pending, skipping...")
            return

        try:
            jbi = self.japi.get_build_info(job_name=self.job_name, build_number=bnum)
            self.logger.debug("check if done")
            # Don't update unless the build is known complete.
            done = jbi.is_done()
            if not done:
                self.logger.debug("not done")
                return

        except Exception as e:
            self.logger.exception("exception processing bnum: {}".format(bnum))
            if not self.meta_coll.schedule_retry(bnum=bnum):
                self.data_coll.store_data(bnum=bnum, data=None)
            return

        # Everybody gets the default aggregator.
        # XXXrs - future black/white list?
        aggregators = [JenkinsJobInfoAggregator(job_name=job_name)]

        # Add any additional aggregators (plugin(s)) registered for the job.
        if additional:
            aggregators.extend(additional)

        send_log = False
        for aggregator in aggregators:
            if aggregator.send_log_to_update:
                send_log = True
                break

        console_log = None
        if send_log:
            try:
                self.logger.debug("get log")
                console_log = jbi.console()
            except Exception as e:
                self.logger.exception("exception processing bnum: {}".format(bnum))
                if not self.meta_coll.schedule_retry(bnum=bnum):
                    self.data_coll.store_data(bnum=bnum, data=None)
                return

        all_data = {}
        for agg in aggregators:
            try:
                self.logger.debug("call update_build")
                if agg.send_log_to_update:
                    data = agg.update_build(bnum=bnum, log=console_log) or {}
                else:
                    data = agg.update_build(bnum=bnum, log=None) or {}

            except JenkinsAggregatorDataUpdateTemporaryError as e:
                # Subclass update_build() encountered a temporary error
                # while trying to gather build information. 
                # Bail, and try again in a bit (if we can).
                self.logger.exception("exception processing bnum: {}".format(bnum))
                if not self.meta_coll.schedule_retry(bnum=bnum):
                    self.data_coll.store_data(bnum=bnum, data=None)
                return

            for k,v in data.items():
                if k in all_data:
                    raise Exception("duplicate key: {}".format(k))
                all_data[k] = v

        if not all_data:
            self.logger.debug("no data")
            # Make an entry indicating there are no data for this build.
            self.data_coll.store_data(bnum=bnum, data=None)
            return

        self.logger.debug("store/index data")
        self.logger.debug(all_data)
        self.data_coll.store_data(bnum=bnum, data=all_data)
        self.meta_coll.index_data(bnum=bnum, data=all_data)

    def update_builds(self):
        self.logger.info("start")

        completed_builds = set(self.data_coll.all_builds())
        self.logger.debug("completed builds: {}".format(completed_builds))

        last_build = self.japi.get_job_info(job_name=self.job_name).last_build_number()
        if not last_build:
            return
        possible_builds = set([str(n) for n in range(1, last_build+1)])
        candidate_builds = sorted(possible_builds.difference(completed_builds), key=nat_sort, reverse=True)
        for bnum in candidate_builds[:self.builds_max]:
            self._update_build(bnum=bnum)

# MAIN -----

cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                        'UPDATE_JOB_LIST': {'default': None}})

# It's log, it's log... :)
logging.basicConfig(level=cfg.get('LOG_LEVEL'),
                    format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                    handlers=[logging.StreamHandler()])
logger = logging.getLogger(__name__)

db = MongoDB()

process_lock = None
try:
    plugins = Plugins()
    job_list = cfg.get('UPDATE_JOB_LIST')
    if job_list:
        job_list = job_list.split(',')
    else:
        logger.info("no job list")
        job_list = JenkinsApi().list_jobs()
    logger.info("job list: {}".format(job_list))
    for job_name in job_list:
        logger.info("process {}".format(job_name))

        # Try to obtain the process lock
        process_lock_name = "{}_process_lock".format(job_name)
        process_lock_meta = {"reason": "locked by JenkinsJobAggregators for update_builds()"}
        process_lock = MongoDBKeepAliveLock(db=db, name=process_lock_name)
        try:
            process_lock.lock(meta=process_lock_meta)
        except MongoDBKALockTimeout as e:
            self.logger.info("timeout acquiring {}".format(process_lock_name))
            continue

        additional = plugins.by_job(job_name=job_name)
        JenkinsJobAggregators(job_name=job_name, db=db, additional=additional).update_builds()
        process_lock.unlock()

except Exception as e:
    # XXXrs - FUTURE - context manager for keep-alive lock
    if process_lock is not None:
        process_lock.unlock()
    raise
