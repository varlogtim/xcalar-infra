#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import logging
import os
import re
import subprocess

from py_common.env_configuration import EnvConfiguration

class GitHelper(object):
    """
    Class implementing useful git helper methods within the
    Xcalar git environment.
    """

    ENV_PARAMS = {'XCE_GIT_REPOSITORY': {'default': 'ssh://gerrit.int.xcalar.com:29418/xcalar.git',
                                         'required': True},
                  'XD_GIT_REPOSITORY': {'default': 'ssh://gerrit.int.xcalar.com:29418/xcalar/xcalar-gui.git',
                                        'required': True},
                  'INFRA_GIT_REPOSITORY': {'default': 'ssh://gerrit.int.xcalar.com:29418/xcalar/xcalar-infra.git',
                                           'required': True},
                  'GIT_REPO_CLONE_ROOT': {'default': '/var/tmp/py_xcalargitrepos',
                                          'required': True}}

    REPO_TO_LOCAL_DIR = {'XCE_GIT_REPOSITORY': 'xcalar',
                         'XD_GIT_REPOSITORY': 'xcalar-gui',
                         'INFRA_GIT_REPOSITORY': 'xcalar-infra'}

    REMOTES_PAT = re.compile(r"\Aremotes/origin/(?!HEAD)(.*)\Z")
    FETCH_PAT = re.compile(r"\AFetching upstream changes from (.*)\Z")
    CHECKOUT_PAT = re.compile(r"\AChecking out Revision ([a-f0-9]*) \((.*)\)\Z")

    def __init__(self):
        """
        Initializer.
        """
        self.cfg = EnvConfiguration(GitHelper.ENV_PARAMS)
        self.logger = logging.getLogger(__name__)
        self.commits_cache = {} # XXXrs - FUTURE - persist somewhere
        self.update_repos()

    def update_repos(self):

        # Create the clone root if needed
        clone_root = self.cfg.get('GIT_REPO_CLONE_ROOT')
        os.makedirs(clone_root, exist_ok=True)

        # Populate as needed
        for name,directory in GitHelper.REPO_TO_LOCAL_DIR.items():
            path = os.path.join(clone_root, directory)
            # clone if not already in place
            if not os.path.exists(path):
                repo = self.cfg.get(name)
                cmd = "git clone {} {}".format(repo, path)
                cp = subprocess.run(['git', 'clone', repo, path],
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE,
                                    universal_newlines=True)
                self.logger.debug("clone {}".format(cp))
            else:
                # pull latest
                cp = subprocess.run(['git', 'pull'],
                                    cwd=path,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE,
                                    universal_newlines=True)
                self.logger.debug("pull {}".format(cp))

    def contained_in(self, *, commit, _update_repos_on_fail=False):
        """
        Search XCE/XD/INFRA for branches containing the given commit.
        Return: (<repo>, [branch, ...])
        """
        if commit in self.commits_cache:
            self.logger.debug("commit: {} in cache".format(commit))
            return self.commits_cache[commit]
        any_found = False
        rtn = (None, None)
        clone_root = self.cfg.get('GIT_REPO_CLONE_ROOT')
        for name,directory in GitHelper.REPO_TO_LOCAL_DIR.items():
            self.logger.debug("checking: {}".format(name))
            path = os.path.join(clone_root, directory)
            cp = subprocess.run(['git', 'branch', '-a', '--contains', commit],
                                cwd=path,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                universal_newlines=True)
            if cp.returncode:
                self.logger.debug("not found, skip...")
                continue
            any_found = True
            lines = [s.strip() for s in cp.stdout.strip().split('\n')]
            self.logger.debug("lines: {}".format(lines))
            branches = [m.group(1) for l in lines for m in [GitHelper.REMOTES_PAT.search(l.strip())] if m]
            rtn = (name, branches)
            break
        if not any_found and _update_repos_on_fail:
            #
            # Might be looking at a commit entered into the repo since we last
            # refreshed.  How to tell we're not refreshing "too often"?
            # Caller should explicitly call refresh?
            #
            self.logger.debug("no results, update repos and retry")
            self.update_repos()
            return self.contained_in(commit=commit, _update_repos_on_fail=False)
        self.commits_cache[commit] = rtn
        self.logger.debug("return: {}".format(rtn))
        return rtn

    def commits(self, *, log):
        commits = {}
        lastfetch = None
        for line in log.splitlines():
            m = GitHelper.FETCH_PAT.match(line)
            if m:
                lastfetch = m.group(1)
                next
            m = GitHelper.CHECKOUT_PAT.match(line)
            if m:
                commit = m.group(1)
                repo, branches = self.contained_in(commit=commit)
                commits[commit]={'repo': repo, 'branches': branches}
        return commits


# In-line "unit test"
if __name__ == '__main__':
    from py_common.jenkins_api import JenkinsApi
    print("Compile check A-OK!")

    cfg = EnvConfiguration({'LOG_LEVEL': {'default': logging.INFO},
                            'JENKINS_HOST': {'default': 'jenkins.int.xcalar.com'}})

    logging.basicConfig(level=cfg.get('LOG_LEVEL'),
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    japi = JenkinsApi(jenkins_host=cfg.get('JENKINS_HOST'))
    log = japi.console(job_name="XDUnitTest", build_number=8522)

    gh = GitHelper()
    print(gh.commits(log=log))

    """
    commits = ['dba33598d0d563745708482d552fd314e8167a8b',
               '165e213e76a9006a1b1e64e2e63ae1861c647412',
               'dba33598d0d563745708482d552fd314e8167a8b',
               '550ccd267dd48ddf6b9e9cf42078c962775fef20',
               '9ac0e5830ff28dad21029efe77da5dcddf74c134',
               '4c97fea93b397fc1bc5864089c31023c453f5b1e',
               '8fb100ce5dad0b455885cc27ff161fd83ebd6ab2',
               '4de963e8e2e27ce0fa676ffe6e685cd42c60f3fa',
               '78352f7e7f95af59fe331044a39d2933ffd8e01d',
               'd5824eeb5715f7fef4e0b028a14aa0fd053bccb0',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a',
               '9fae01eba23a5b8f1c86829420384cbd203a0b4a']
    for commit in commits:
        print("commit: {}".format(commit))
        rtn = gh.contained_in(commit=commit)
        print("contained in: {}".format(rtn))
    """
