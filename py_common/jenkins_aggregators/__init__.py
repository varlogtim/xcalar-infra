#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

__all__=[]

from abc import ABC, abstractmethod
import json
import logging
import os
import pymongo
from pymongo.errors import DuplicateKeyError
from pymongo import ReturnDocument
import re
import signal
import sys
import time

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_api import JenkinsApi
from py_common.mongo import MongoDB, JenkinsMongoDB
from py_common.sorts import nat_sort


class JenkinsAllJobIndex(object):
    """
    Interface to the collections that keep particular meta-data
    spanning multiple jobs.
    """

    def __init__(self, *, jmdb):
        self.logger = logging.getLogger(__name__)
        self.jmdb = jmdb

    def index_data(self, *, job_name, bnum, data):
        """
        Expects to find at least the following in data:
            {'parameters': jbi.parameters(),
             'git_branches': jbi.git_branches(),
             'built_on': jbi.built_on(),
             'start_time_ms': jbi.start_time_ms(),
             'duration_ms': jbi.duration_ms(),
             'result': jbi.result()}
        """
        self.logger.debug("job_name: {} bnum: {}".format(job_name, bnum))

        # XXXrs - more fields?
        start_time_ms = data.get('start_time_ms', None)
        job_entry = {'job_name': job_name,
                     'build_number': bnum,
                     'start_time_ms': start_time_ms,
                     'duration_ms': data.get('duration_ms', None),
                     'built_on': data.get('built_on', None),
                     'result': data.get('result', None)}

        self.logger.debug("job_entry: {}".format(job_entry))

        # Jobs by time
        if start_time_ms is not None:
            coll = self.jmdb.jobs_by_time_collection(time_ms=start_time_ms)
            coll.create_index([('job_name', pymongo.ASCENDING),
                               ('build_number', pymongo.ASCENDING)],
                              unique=True)
            try:
                coll.insert(job_entry)
            except DuplicateKeyError as e:
                self.logger.debug("jobs_by_time duplicate {}".format(job_entry))

        # Downstream Jobs
        coll = self.jmdb.downstream_jobs()
        down_key = "{}:{}".format(job_name, bnum)
        for item in data.get('upstream', []):
            self.logger.debug('upstream: {}'.format(item))
            up_jname = item.get('job_name', None)
            if not up_jname:
                self.logger.debug("missing expected upstream job_name: {}".format(item))
                continue
            up_bnum = item.get('build_number', None)
            if not up_bnum:
                self.logger.debug("missing expected upstream build_number: {}".format(item))
                continue
            up_key = "{}:{}".format(up_jname, up_bnum)
            self.logger.debug("up_key {} down_key {}".format(up_key, down_key))
            coll.find_one_and_update({'_id': up_key},
                                     {'$addToSet': {'down': down_key}},
                                     upsert = True)

    def jobs_by_time(self, *, start, end):
        start_ms = start*1000
        end_ms = end*1000
        query = {'$and': [{'start_time_ms': {'$gte': start_ms}},
                          {'start_time_ms': {'$lte': end_ms}}]}
        colls = self.jmdb.jobs_by_time_collections(
                                        start_time_ms=start_ms,
                                        end_time_ms=end_ms)
        jobs = []
        for coll in colls:
            docs = coll.find(query)
            if not docs:
                continue
            for doc in docs:
                doc.pop('_id')
                jobs.append(doc)
        return {'jobs': jobs}

    def _get_downstream(self, *, job_name, bnum):
        rtn = []
        key = "{}:{}".format(job_name, bnum)
        doc = self.jmdb.downstream_jobs().find_one({'_id': key})
        if not doc:
            return None
        for downkey in doc.get('down'):
            job_name, bnum = downkey.split(':')
            rtn.append({'job_name': job_name,
                        'build_number': bnum,
                        'downstream': self._get_downstream(job_name=job_name, bnum=bnum)})
        if not len(rtn):
            return None
        return rtn

    def downstream_jobs(self, *, job_name, bnum):
        return {'downstream': self._get_downstream(job_name=job_name, bnum=bnum)}


class JenkinsJobDataCollection(object):
    """
    Interface to the per-build job data collection.
    """
    def __init__(self, *, job_name, db):
        self.logger = logging.getLogger(__name__)
        self.coll = db.collection(job_name)

    def _no_data(self, *, doc):
        return not doc or 'NODATA' in doc

    def store_data(self, *, bnum, data):
        """
        Store the passed data, or no-data marker if data is None
        """
        if data is None:
            self.coll.insert({'_id': bnum, 'NODATA':True})
        else:
            data['_id'] = bnum
            self.coll.insert(data)
    def get_data(self, *, bnum):
        self.logger.debug("start bnum {}".format(bnum))
        # Return the data, if any.
        doc = self.coll.find_one({'_id': bnum})
        if self._no_data(doc=doc):
            self.logger.debug("return None")
            return None
        self.logger.debug("return match")
        return doc

    def get_data_by_build(self):
        self.logger.debug("start")
        rtn = {}
        for doc in self.coll.find({}):
            doc_id = doc["_id"]
            self.logger.debug("_id: {}".format(doc_id))
            if self._no_data(doc=doc):
                continue
            rtn[doc_id] = doc
        self.logger.debug("rtn: {}".format(rtn))
        return rtn

    def all_builds(self):
        """
        Return the list of all completed builds (builds which have an entry here)
        """
        builds = []
        for doc in self.coll.find({}, projection={'_id':1}):
            builds.append(doc['_id'])
        return sorted(builds)


class JenkinsJobMetaCollection(object):
    """
    Interface to the per-job meta-data collection.
    """
    ENV_PARAMS = {'JENKINS_AGGREGATOR_UPDATE_RETRY_MAX':
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 3},
                  'JENKINS_AGGREGATOR_UPDATE_RETRY_SEC':
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 300} }

    def __init__(self, *, job_name, db):
        self.logger = logging.getLogger(__name__)
        self.coll = db.collection("{}_meta".format(job_name))
        cfg = EnvConfiguration(JenkinsJobMetaCollection.ENV_PARAMS)
        self.retry_max = cfg.get('JENKINS_AGGREGATOR_UPDATE_RETRY_MAX')
        self.retry_sec = cfg.get('JENKINS_AGGREGATOR_UPDATE_RETRY_SEC')

    def index_data(self, *, bnum, data):
        """
        Extract certain meta-data from the data set and "index".
        This is largly for the purpose of dashboard time efficiency.
        This may become obsolete when data are processed/indexed via
        Xcalar.
        """
        if not data:
            return # Nothing to do

        # Add to all_builds list
        self.coll.find_one_and_update({'_id': 'all_builds'},
                                      {'$addToSet': {'builds': bnum}},
                                      upsert = True)

        # If we have branch data, add to the builds-by-branch list(s)
        git_branches = data.get('git_branches', {})
        for repo, branch in git_branches.items():

            # Add repo to all repos list
            self.coll.find_one_and_update({'_id': 'all_repos'},
                                          {'$addToSet': {'repos': repo}},
                                          upsert = True)

            # Add branch to list of branches for the repo
            key = MongoDB.encode_key("{}_branches".format(repo))
            self.coll.find_one_and_update({'_id': key},
                                          {'$addToSet': {'branches': branch}},
                                          upsert = True)

            # Add build to the list of builds for the repo/branch pair
            key = MongoDB.encode_key("{}_{}_builds".format(repo, branch))
            self.coll.find_one_and_update({'_id': key},
                                          {'$addToSet': {'builds': bnum}},
                                           upsert = True)

        # _add_to_meta_list is a list of key/val pairs.  The key will define a document,
        # and the val will be appended to the 'values' list in that document.
        add_to_meta_list = data.pop('_add_to_meta_list', [])
        for key,val in add_to_meta_list:
            self.coll.find_one_and_update({'_id': key},
                                          {'$push': {'values': val}},
                                          upsert = True)

        # _add_to_meta_set is a list of key/val pairs.  The key will define a document,
        # and the val will be added to the 'values' set in that document iff it is not
        # already present.
        add_to_meta_set = data.pop('_add_to_meta_set', [])
        for key,val in add_to_meta_set:
            self.coll.find_one_and_update({'_id': key},
                                          {'$addToSet': {'values': val}},
                                          upsert = True)


    def all_builds(self):
        """
        Return the list of all builds for which we have indexed data.
        """
        doc = self.coll.find_one({'_id': 'all_builds'})
        if not doc:
            return []
        return sorted(doc.get('builds', []))

    def schedule_retry(self, *, bnum):
        """
        Called when an attempt to obtain update data encounters a
        (presumably) temporary failure.  Will track the number of
        try attempts already made, and update the "try after" timestamp
        which prevents retrying "too fast".

        Returns true if another try is allowed in the future,
        false if retries are exhausted.
        """
        if self.retry_max <= 1:
            return False

        doc = self.coll.find_one_and_update({'_id': 'retry'},
                                            {'$inc': {'{}.count'.format(bnum): 1},
                                             '$set': {'{}.after'.format(bnum):
                                                 time.time()+self.retry_sec}},
                                            upsert = True,
                                            return_document = ReturnDocument.AFTER)

        return doc[bnum]['count'] < self.retry_max

    def retry_pending(self, *, bnum):
        """
        Return true if we have a retry entry for the build,
        and it's telling us to retry at a later time.
        """
        doc = self.coll.find_one({'_id': 'retry', bnum:{'$exists': True}},
                                 projection={bnum: True})
        if not doc:
            return False
        count = doc[bnum].get('count', None)
        if count is None or count >= self.retry_max:
            return False
        after = doc[bnum].get('after', None)
        if after is None:
            return False
        return time.time() < after

    def repos(self):
        # Return all known repos
        doc = self.coll.find_one({'_id': 'all_repos'})
        if not doc:
            return []
        return list(doc.get('repos', []))

    def branches(self, *, repo):
        # Return all known branches for the repo
        key = MongoDB.encode_key('{}_branches'.format(repo))
        doc = self.coll.find_one({'_id': key})
        if not doc:
            return []
        return list(doc.get('branches', []))

    def find_builds(self, *, repo=None,
                             branches=None,
                             first_bnum=None,
                             last_bnum=None,
                             reverse=False):
        """
        Return list (possibly empty) of build numbers matching the
        given attributes.
        """

        if branches and not repo:
            raise ValueError("branches requires repo")
        # n.b. repo without branches is a no-op

        all_builds = self.all_builds()
        if not all_builds:
            return []
        if first_bnum or last_bnum and not (first_bnum and last_bnum):
            if not first_bnum:
                first_bnum = all_builds[0]
            if not last_bnum:
                last_bnum = all_builds[-1]

        build_range = None
        if first_bnum:
            build_range = set([str(b) for b in  range(int(first_bnum), int(last_bnum)+1)])

        avail_builds = set()
        if repo:
            # Just those matching repo/branch
            for branch in branches:
                key = MongoDB.encode_key("{}_{}_builds".format(repo, branch))
                doc = self.coll.find_one({'_id': key})
                if not doc:
                    continue
                avail_builds.update(doc.get('builds', []))
        else:
            avail_builds.update(all_builds)

        # If our build range is limited, intersect...
        if build_range:
            build_list = list(avail_builds.intersection(build_range))
        else:
            build_list = list(avail_builds)

        return sorted(build_list, key=nat_sort, reverse=reverse)


class JenkinsAggregatorDataUpdateTemporaryError(Exception):
    """
    Raised by subclass if update_build() encounters a failure that may be
    temporary and which may go away with a subsequent retry.
    """
    pass


class JenkinsAggregatorBase(ABC):
    """
    Base class for aggregating data and meta-data
    associated with a specific Jenkins job.
    """
    def __init__(self, *, job_name, send_log_to_update = False):
        """
        Initializer.

        Required parameters:
            job_name:   Jenkins job name

        Optional parmaeters:
            send_log_to_update: whether or not to send the full Jenkins
                                console log to the update_build() method
                                as the value of the "log" parameter.
                                Default is False.
        """
        self.logger = logging.getLogger(__name__)
        self.job_name = job_name
        self.send_log_to_update = send_log_to_update

    @abstractmethod
    def update_build(self, *, bnum, jbi, log):
        """
        Aggregate and return build-related data and meta-data.
        Every aggregator must implement the update_build() method.

        Required Parameters:
            bnum: build number
            jbi:  JenkinsBuildInfo instance (if not available will be passed as None)
            log:  the associated console log if requested via send_log_to_update
                  initializer parameter.  Will be set to None if not requested.

        Returns:
            Data structure to be associated with the build number (if any).
        """
        pass


class JenkinsJobInfoAggregator(JenkinsAggregatorBase):
    """
    Default Jenkins data aggregation.
    Returns common Jenkins-supplied build information.
    Used for all jobs.
    """
    def __init__(self, *, jenkins_host, job_name):
        super().__init__(job_name=job_name)
        self.logger = logging.getLogger(__name__)
        self.japi = JenkinsApi(jenkins_host=jenkins_host)
        self.jbi_by_bnum = {}

    def build_info(self, *, bnum):
        jbi = self.jbi_by_bnum.get(bnum, None)
        if jbi:
            return jbi
        jbi = self.japi.get_build_info(job_name = self.job_name,
                                       build_number = bnum)
        self.jbi_by_bnum[bnum] = jbi
        return jbi

    def update_build(self, *, bnum, jbi, log):
        rtn = {}
        try:
            # This is the "standard" set of job data.
            # Note that the JenkinsAllJobIndex class counts
            # on what's here.
            rtn = {'parameters': jbi.parameters(),
                   'git_branches': jbi.git_branches(),
                   'built_on': jbi.built_on(),
                   'start_time_ms': jbi.start_time_ms(),
                   'duration_ms': jbi.duration_ms(),
                   'result': jbi.result()}
            upstream = jbi.upstream()
            if upstream:
                rtn['upstream'] = upstream
            self.jbi = jbi
        except Exception as e:
            self.logger.exception("failed to get build info")
            raise JenkinsAggregatorDataUpdateTemporaryError("try again") from None

        self.logger.debug("rtn: {}".format(rtn))
        return rtn

from importlib import import_module

class Plugins(object):

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        plugins_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                                   "plugins")
        self.byjob = {}
        for name in os.listdir(plugins_dir):
            if not name.endswith('.py'):
                continue
            mname = name[:-3]
            mpath = "plugins.{}".format(mname)
            try:
                mod = import_module(mpath)
            except:
                self.logger.exception("exception importing module: {}"
                                      .format(mpath))
                raise

            try:
                defs = getattr(mod, 'PLUGIN')
                self.logger.debug("loaded: {}".format(mname))
                self.logger.debug("PLUGIN defs: {}".format(defs))
            except AttributeError as e:
                self.logger.info("falied to find PLUGIN defs: {}".format(mname))
                continue

            for info in defs:
                for job_name in info.get('job_names'):
                    mpath = info.get('module_path', None)
                    if mpath:
                        try:
                            mod = import_module(mpath)
                        except:
                            self.logger.exception("exception importing module: {}"
                                                  .format(mpath))
                            raise
                    cname = info.get('class_name')
                    cls = getattr(mod, cname)(job_name=job_name)
                    self.byjob.setdefault(job_name, []).append(cls)

    def by_job(self, *, job_name):
        return self.byjob.get(job_name, [])

# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")

    cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                            'JENKINS_HOST': {'default': 'jenkins.int.xcalar.com'}})

    # It's log, it's log... :)
    logging.basicConfig(
                    level=cfg.get('LOG_LEVEL'),
                    format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                    handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    jmdb = JenkinsMongoDB(jenkins_host=cfg.get('JENKINS_HOST'))
    logger.info('jmdb: {}'.format(jmdb))
    alljob_idx = JenkinsAllJobIndex(jmdb=jmdb)
    logging.info(alljob_idx)
    logging.info(alljob_idx.downstream_jobs(job_name='DailyTests-Trunk', bnum='153'))

    """
    job_names = [n for n in byjob_db.db.collection_names() if not n.endswith('_meta') and not n.startswith('_')]
    logging.info(job_names)

    for job_name in job_names:
        job_coll = byjob_db.collection(job_name)
        for doc in job_coll.find({}):
            alljob_db.index_data(job_name=job_name, bnum=doc['_id'], data=doc)

    """
