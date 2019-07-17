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
import threading
import time

from py_common.env_configuration import EnvConfiguration
from py_common.git_helper import GitHelper
from py_common.jenkins_api import JenkinsApi, JenkinsAPIError
from py_common.mongo import MongoDB
from py_common.sorts import nat_sort


class JenkinsArtifacts(object):
    """
    Base class for accessing Jenkins artifacts.
    """

    artifacts_subdir_pat = re.compile(r"\A(\d*)\Z")

    def __init__(self, *, job_name, dir_path=None):
        """
        Initializer
        """
        self.logger = logging.getLogger(__name__)
        self.job_name = job_name
        self.dir_path = dir_path
        self.japi = JenkinsApi()

    def _builds_from_directory(self):
        """
        Return the list of all build numbers within the artifacts directory.
        List will be sorted into "natural" number order
        (e.g. "10" comes after "9", not "1").
        """
        self.logger.debug("start")
        builds = []
        if not self.dir_path:
            return builds
        for bnum in os.listdir(self.dir_path):
            if not JenkinsArtifacts.artifacts_subdir_pat.match(bnum):
                self.logger.debug("skipping: {}".format(bnum))
                continue
            builds.append(bnum)
        rtn = sorted(builds, key=nat_sort, reverse=True)
        self.logger.debug("end: {}".format(rtn))
        return rtn

    def _builds_from_jenkins(self):
        """
        Return the list of all builds (possibly) known for the job by the Jenkins host.
        List will be sorted into "natural" number order
        (e.g. "10" comes after "9", not "1").
        """
        self.logger.debug("start")
        builds = [str(bn+1) for bn in range(0,self.japi.last_build_number(job_name=self.job_name))]
        rtn = sorted(builds, key=nat_sort, reverse=True)
        self.logger.debug("end: {}".format(rtn))
        return rtn

    def builds(self):
        """
        Return the list of available builds with artifacts.
        Defaults to list of builds represented in the given artifacts directory.
        Override if you have alternate needs.
        """
        return self._builds_from_directory()
            
    def artifacts_directory_path(self, *, bnum):
        """
        Return the path to the build's specific artifacts directory.
        Defaults to <dir_path>/<bnum>
        Override if you have alternate needs.

        Required Parameter:
            bnum: build number

        Returns:
            Path to build's specific artifacts directory.
        """
        if not self.dir_path:
            return None
        return os.path.join(self.dir_path, bnum)


class JenkinsArtifactsDataUpdateTemporaryError(Exception):
    """
    Raised by subclass if update_build() encounters a failure that may be
    temporary and which may go away with a subsequent retry.
    """
    pass


class JenkinsArtifactsData(ABC):
    """
    Class representing indexed data and meta-data associated with a set
    of Jenkins builds.
    """
    ENV_CONFIG = {'JENKINS_ARTIFACTS_DATA_REFRESH_SEC': # Update/refresh this often
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 60},
                  'JENKINS_ARTIFACTS_DATA_UPDATE_MAX_TRIES':
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 3},
                  'JENKINS_ARTIFACTS_DATA_UPDATE_RETRY_SEC':
                    {'required': True,
                     'type': EnvConfiguration.NUMBER,
                     'default': 120} }

    update_event = threading.Event()
    update_stop = False

    def __init__(self, *, jenkins_artifacts,
                          send_log_to_update=False,
                          add_commits=False):
        """
        Initializer.

        Required parameters:
            jenkins_artifacts:  JenkinsArtifacts instance
        """
        self.logger = logging.getLogger(__name__)
        if not jenkins_artifacts.job_name:
            raise ValueError("jenkins_artifacts has no associated job name")
        if not jenkins_artifacts.dir_path:
            raise ValueError("jenkins_artifacts has no associated directory")
        self.jenkins_artifacts = jenkins_artifacts
        cfg = EnvConfiguration(JenkinsArtifactsData.ENV_CONFIG)
        self.refresh_sec = cfg.get('JENKINS_ARTIFACTS_DATA_REFRESH_SEC')
        self.retry_sec = cfg.get('JENKINS_ARTIFACTS_DATA_UPDATE_RETRY_SEC')
        self.max_tries = cfg.get('JENKINS_ARTIFACTS_DATA_UPDATE_MAX_TRIES')
        self.data_stale = 0
        self.mongo = MongoDB()
        self.data_coll = self.mongo.collection(jenkins_artifacts.job_name)
        self.meta_coll = self.mongo.collection("{}_meta".format(jenkins_artifacts.job_name))

        self.japi = JenkinsApi()
        if add_commits:
            # This indicates we want commit info added to the data
            self.git_helper = GitHelper()
        self.send_log_to_update = send_log_to_update
        self.update_thread = None

    def stop_update_thread(self):
        self.logger.info("start")
        if not self.update_thread:
            self.logger.error("stopping update thread without starting")
            return
        JenkinsArtifactsData.update_stop = True
        JenkinsArtifactsData.update_event.set()
        self.update_thread.join(timeout=60)
        if self.update_thread.is_alive():
            self.logger.error("timeout joining update thread")
        self.update_thread = None
        self.logger.info("end")

    def start_update_thread(self):
        self.logger.info("start")

        if self.update_thread:
            self.logger.error("update thread already running")
            return

        # Update DB regularly in the background
        self.update_thread = threading.Thread(target = self._update_main)
        self.update_thread.daemon = True
        self.update_thread.start()

        def shutdown(signal_number, frame):
            self.stop_update_thread()
            sys.exit()

        # Stop on common signals
        signal.signal(signal.SIGINT, shutdown)
        signal.signal(signal.SIGHUP, shutdown)
        signal.signal(signal.SIGTERM, shutdown)

        self.logger.info("end")

    def _update_build(self, *, bnum):
        self.logger.info("process bnum: {}".format(bnum))
        # Already have a data entry?
        if self.data_coll.find_one({'_id': bnum}):
            self.logger.debug("already seen, skipping...")
            return

        # Waiting for retry timeout?
        if self._retry_pending(bnum = bnum):
            self.logger.debug("retry pending, skipping...")
            return

        # Try to obtain the data.
        try:
            # Don't call update_build() unless the build is known complete.
            done = self.japi.is_done(job_name=self.jenkins_artifacts.job_name,
                                     build_number=bnum)
            if not done:
               return

        except JenkinsAPIError as e:
            self.logger.exception("exception processing bnum: {}".format(bnum))
            if not self._schedule_retry(bnum=bnum):
                self._store_data(bnum=bnum, data=None)
            return

        log = None
        try:
            if self.send_log_to_update:
                log = self._build_log(bnum=bnum)
            data = self.update_build(bnum=bnum, log=log) or {}
        except JenkinsArtifactsDataUpdateTemporaryError as e:
            # update_build() encountered a temporary error while trying to gather
            # build information.  Try again in a bit.
            self.logger.exception("exception processing bnum: {}".format(bnum))
            if not self._schedule_retry(bnum=bnum):
                self._store_data(bnum=bnum, data=None)
            return

        if not data:
            # Make an entry indicating there are no data for this build.
            self._store_data(bnum = bnum, data = {'NODATA':True})
            return

        # Add commits if asked
        if data and 'commits' not in data and hasattr(self, "git_helper"):
            if not log:
               log = self._build_log(bnum=bnum)
            data['commits'] = self._git_commits(log=log)
        self._store_data(bnum = bnum, data = data)

    def _update_main(self):
        self.logger.info("start")
        first = True
        while not JenkinsArtifactsData.update_stop:
            if first or not JenkinsArtifactsData.update_event.wait(self.refresh_sec):
                first = False
                self.logger.info("do updates")

                if hasattr(self, "git_helper"):
                    self.git_helper.update_repos()
                    self.start_update()

                for bnum in self.jenkins_artifacts.builds():
                    self._update_build(bnum = bnum)
                    if JenkinsArtifactsData.update_stop:
                        break
        self.logger.info("stop")

    def _retry_pending(self, *, bnum):
        """
        Return true if we have a retry entry for the build,
        and it's telling us to retry at a later time.
        """
        doc = self.meta_coll.find_one({'_id': 'retry', bnum:{'$exists': True}},
                                      projection={bnum: True})
        if not doc:
            return False
        after = doc[bnum].get('after', None)
        if after is None:
            return False
        return time.time() < after

    def _schedule_retry(self, *, bnum):
        """
        Called when an attempt to obtain update data encounters a
        (presumably) tempoarary failure.  Will track the number of
        try attempts already made, and update the "try after" timestamp
        which prevents retrying "too fast".

        Returns true if another try is allowed in the future,
        false if no retries are exhausted.
        """
        if self.max_tries <= 1:
            return False

        doc = self.data_coll.find_one({'_id': bnum})
        if doc:
            # Already have a matching document with data.
            return False

        doc = self.meta_coll.find_one_and_update({'_id': 'retry'},
                                                 {'$inc': {'{}.count'.format(bnum): 1},
                                                  '$set': {'{}.after'.format(bnum):
                                                      time.time()+self.retry_sec}},
                                                 upsert = True,
                                                 return_document = ReturnDocument.AFTER)
        return doc[bnum]['count'] < self.max_tries

    def _store_data(self, *, bnum, data):
        self.logger.debug("update {}: {}".format(bnum, data))

        nodata = not data
        if nodata:
            data = {'NODATA':True}

        # Record the data (or lack thereof)
        try:
            self.data_coll.insert({'_id': bnum, 'data': data})
        except DuplicateKeyError as e:
            self.logger.exception("duplicate data key")

        # Remove any retry entry
        self.meta_coll.find_one_and_update({'_id': 'retry'}, {'$unset':{bnum: ''}})

        # If no data for this build, nothing else to do
        if nodata:
            return

        # Add to all_builds list
        self.meta_coll.find_one_and_update({'_id': 'all_builds'},
                                           {'$addToSet': {'builds': bnum}},
                                           upsert = True)

        # If we have commit data, add to the builds-by-branch list(s)
        commits = data.get('commits', None)
        if commits:
            for commit,cinfo in commits.items():
                if not cinfo:
                    continue
                repo = cinfo.get('repo', None)
                if repo is None:
                    continue
                # Add repo to all repos list
                self.meta_coll.find_one_and_update({'_id': 'all_repos'},
                                                   {'$addToSet': {'repos': repo}},
                                                   upsert = True)

                for branch in cinfo.get('branches', []):
                    # Add branch to list of branches for the repo
                    key = MongoDB.encode_key("{}_branches".format(repo))
                    self.meta_coll.find_one_and_update({'_id': key},
                                                       {'$addToSet': {'branches': branch}},
                                                       upsert = True)

                    # Add build to the list of builds for the repo/branch pair
                    key = MongoDB.encode_key("{}_{}_builds".format(repo, branch))
                    self.meta_coll.find_one_and_update({'_id': key},
                                                       {'$addToSet': {'builds': bnum}},
                                                       upsert = True)

    def _build_log(self, *, bnum):
        return self.japi.console(job_name=self.artifacts.job_name,
                                 build_number=bnum)

    def _git_commits(self, *, log):
        return self.git_helper.commits(log=log)

    def repos(self):
        # Return all known repos
        doc = self.meta_coll.find_one({'_id': 'all_repos'})
        if not doc:
            return []
        return list(doc.get('repos', []))

    def branches(self, *, repo):
        # Return all known branches for the repo
        key = MongoDB.encode_key('{}_branches'.format(repo))
        doc = self.meta_coll.find_one({'_id': key})
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
                first_bnum = all_builds[-1]
            if not last_bnum:
                last_bnum = all_builds[0]

        build_range = None
        if first_bnum:
            build_range = set([str(b) for b in  range(int(first_bnum), int(last_bnum)+1)])

        avail_builds = set()
        if repo:
            # Just those matching repo/branch
            for branch in branches:
                key = MongoDB.encode_key("{}_{}_builds".format(repo, branch))
                doc = self.meta_coll.find_one({'_id': key})
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

    def all_builds(self):
        doc = self.meta_coll.find_one({'_id': 'all_builds'})
        if not doc:
            return []
        return doc.get('builds', [])

    def _have_data(self, *, doc):
        return doc and 'data' in doc and 'NODATA' not in doc['data']

    def get_data(self, *, bnum):
        doc = self.data_coll.find_one({'_id': bnum})
        if not self._have_data(doc=doc):
            return None
        return doc['data']

    def get_data_by_build(self):
        rtn = {}
        for doc in self.data_coll.find({}):
            if not self._have_data(doc=doc):
                continue
            rtn[doc['_id']] = doc['data']
        return rtn

    def start_update(self):
        """
        Called when about to update indexed data.
        Default is to do nothing.
        Override if you have special needs.
        """
        pass

    @abstractmethod
    def update_build(self, *, bnum, log=None):
        """
        Required Parameter:
            bnum:   build number

        Optional Parameter:
            log:    the associated console log if requested via send_log_to_update
                    initializer parameter
        Returns:
            Data structure to be associated with the build number (if any).
        """
        pass


# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")







