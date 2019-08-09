#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import json
import logging
import os
import requests
import subprocess

# XXXrs - some magic to silence unwanted (?) security chatter...
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

from py_common.env_configuration import EnvConfiguration

class JenkinsAPIError(Exception):
    pass

class JenkinsApi(object):
    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.cfg = EnvConfiguration({'JENKINS_HOST':       {'required': True,
                                                            'default': 'jenkins.int.xcalar.com'},
                                     'JENKINS_SSH_PORT':   {'required': True,
                                                            'type': EnvConfiguration.NUMBER,
                                                            'default': 22022},
                                     'USER':               {'required': True,
                                                            'default': 'jenkins'}})
        self.url_root="https://{}".format(self.cfg.get('JENKINS_HOST'))
        self.job_info_cache = {}
        self.build_info_cache = {}

    def _ssh_cmd(self, *, cmd):

        cargs = ["ssh"]
        cargs.append("-oPort={}".format(self.cfg.get('JENKINS_SSH_PORT')))
        cargs.append("-oUser={}".format(self.cfg.get('USER')))
        cargs.append(self.cfg.get('JENKINS_HOST'))
        cargs.append(cmd)

        # XXXrs - send stderr to DEVNULL because keep getting the following kind of noise
        #         even though otherwise all seems perfectly fine.
        #
        #org.apache.sshd.common.SshException: flush(ChannelOutputStream[ChannelSession[id=0, recipient=0]-ServerSessionImpl[rstephens@/10.10.7.25:36154]] SSH_MSG_CHANNEL_DATA) length=0 - stream is already closed
        #   at org.apache.sshd.common.channel.ChannelOutputStream.flush(ChannelOutputStream.java:169)
        #       at org.jenkinsci.main.modules.sshd.AsynchronousCommand$1.run(AsynchronousCommand.java:114)
        #           at java.lang.Thread.run(Thread.java:748)

        self.logger.debug("subprocess.run cargs: {}".format(cargs))
        cp = subprocess.run(cargs, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return cp.stdout.decode('utf-8')

    def _rest_cmd(self, *, uri):
        url = "{}{}".format(self.url_root, uri)
        self.logger.debug("GET URL: {}".format(url))
        response = requests.get(url, verify=False) # XXXrs disable verify!
        if response.status_code != 200:
            return None
        return response.text

    def _get_job_info(self, *, job_name, force=False):
        """
        Return Jenkins job info.  Uses REST API.
        Pass force=True to invalidate previously-cached data
        and refresh the cache.
        """
        info = self.job_info_cache.get(job_name, None)
        if not force and info is not None:
            self.logger.debug("return cached info: {}".format(info))
            return info
        text = self._rest_cmd(uri="/job/{}/api/json".format(job_name))
        if not text:
            return None
        info = json.loads(text)
        self.job_info_cache[job_name] = info
        self.logger.debug("return info: {}".format(info))
        return info

    def _get_build_info(self, *, job_name, build_number, force=False):
        """
        Return Jenkins build info.  Uses REST API.
        Pass force=True to invalidate previously-cached data
        and refresh the cache.
        """
        key = "{}:{}".format(job_name, build_number)
        info = self.build_info_cache.get(key, None)
        if not force and info is not None:
            self.logger.debug("return cached info: {}".format(info))
            return info
        text = self._rest_cmd(uri="/job/{}/{}/api/json".format(job_name, build_number))
        if not text:
            return None
        info = json.loads(text)
        self.build_info_cache[key] = info
        self.logger.debug("return info: {}".format(info))
        return info

    def list_jobs(self):
        jobs = []
        for name in self._ssh_cmd(cmd="list-jobs").splitlines():
            jobs.append(name)
        return jobs

    def last_build_number(self, *, job_name):
        """
        Get the last known build number for a job.
        """
        info = self._get_job_info(job_name=job_name)
        last_build = info.get('lastBuild', None)
        if not last_build:
            self.logger.debug("no last build available")
            return None
        bnum = last_build.get('number', None)
        self.logger.debug("return: {}".format(bnum))
        return bnum

    def is_done(self, *, job_name, build_number):
        """
        Is the job/build complete?
        """
        # Time-specific, so ignore any cache
        info = self._get_build_info(job_name = job_name,
                                    build_number = build_number,
                                    force = True)
        if not info:
            err = "no info for job: {} build: {}".format(job_name, build_number)
            self.logger.error(err)
            raise JenkinsAPIError(err)
        if info and 'building' not in info:
            err = "no building value in info for job: {} build: {}".format(job_name, build_number)
            self.logger.error(err)
            raise JenkinsAPIError(err)
        building = info['building']
        self.logger.info("job: {} build: {} building: {}"
                          .format(job_name, build_number, building))
        return not(building)

    def console(self, *, job_name, build_number = None):
        """
        Return the console log for the job/build.
        """
        cmd = "console {}".format(job_name)
        if build_number:
            cmd += " {}".format(build_number)
        return self._ssh_cmd(cmd=cmd)

    def get_upstream(self, *, job_name, build_number):
        """
        Returns a list of dictionaries identifying upstream build(s):

        [{'job_name':<upstreamProject>, 'build_number':<upstreamBuild>}, ...]
        """
        upstream = []
        info = self._get_build_info(job_name = job_name,
                                    build_number = build_number)
        if not info:
            return upstream
        for action in info.get('actions', []):
            causes = action.get('causes', None)
            if not causes:
                continue
            for cause in causes:
                job_name = cause.get('upstreamProject', None)
                build_number = cause.get('upstreamBuild', None)
                if job_name is None or build_number is None:
                    continue
                upstream.append({'job_name':cause.get('upstreamProject', None),
                                 'build_number':cause.get('upstreamBuild', None)})
        return upstream


if __name__ == '__main__':
    print("Compile check A-OK!")
    logging.basicConfig(level=logging.DEBUG,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    job_name = "XDUnitTest"
    japi = JenkinsApi()

    jobs = japi.list_jobs()
    print("All jobs: {}".format(jobs))
    if job_name not in jobs:
        raise Exception("Unknown job: {}".format(job_name))
    print("Checking job: {}".format(job_name))
    last_build = japi.last_build_number(job_name=job_name)
    print("\tlast build: {}".format(last_build))
    print("\tlast 20 build done status:")
    for i in range(last_build-20,last_build):
        try:
            print("build {} done: {}".format(i+1, japi.is_done(job_name=job_name, build_number=i+1)))
        except Exception as e:
            print("Exception: {}".format(e))
