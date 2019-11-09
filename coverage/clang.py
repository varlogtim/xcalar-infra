#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import gzip
import json
import logging
import os
import re
import subprocess
import sys

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.env_configuration import EnvConfiguration
from py_common.jenkins_aggregators import JenkinsAggregatorBase
from py_common.mongo import MongoDB

class ClangCoverageFilenameCollision(Exception):
    pass

class ClangCoverageEmptyFile(Exception):
    pass

class ClangCoverageNoData(Exception):
    pass

class ClangCoverageNoBinary(Exception):
    pass

class ClangCoverage(object):

    GZIPPED = re.compile(r".*\.gz\Z")

    def __init__(self, *, path):
        self.logger = logging.getLogger(__name__)
        self.path = path
        self.coverage_data = self._load_json()

    def _load_json(self):
        path = self.path
        if not os.path.exists(path):
            # Try gzipped form
            zpath = "{}.gz".format(path)
            if not os.path.exists(zpath):
                err = "neither {} nor {} exist".format(path, zpath)
                self.logger.error(err)
                raise FileNotFoundError(err)
            path = zpath

        jstr = ""
        if self.GZIPPED.match(path):
            with gzip.open(path, "rb") as fh:
                jstr = fh.read().decode("utf-8")
        else:
            with open(path, "r") as fh:
                jstr = fh.read()

        if not len(jstr):
            raise ClangCoverageEmptyFile("{} is empty".format(path))
        return json.loads(jstr)

    def file_summaries(self):
        """
        Strip a full coverage results file down to just per-file summary data.
        Returns dictionary:
            {<file_path>: {<file_summary_data>},
             <file_path>: {<file_summary_data>},
             ...
             "totals": {<total_summary_data}}
        """
        summaries = {}
        if 'data' not in self.coverage_data:
            return summaries
        for info in self.coverage_data['data']:
            totals = info.get('totals', None)
            if totals:
                summaries['totals'] = totals
            for finfo in info['files']:
                filename = finfo.get('filename', None)
                if not filename:
                    continue # :|
                if filename in summaries:
                    raise ClangCoverageFilenameCollision(
                            "colliding file name: {}".format(filename))
                summaries[filename] = finfo.get('summary', None)
        return summaries


class ClangCoverageAggregator(JenkinsAggregatorBase):

    ENV_PARAMS = {"CLANG_BIN_DIR": {"default": "/opt/clang5/bin", "required": True}}

    def __init__(self, *, job_name,
                          coverage_file_name,
                          artifacts_root):

        self.logger = logging.getLogger(__name__)
        cfg = EnvConfiguration(ClangCoverageAggregator.ENV_PARAMS)
        self.coverage_file_name = coverage_file_name
        self.artifacts_root = artifacts_root
        self.clang_bin_dir = cfg.get("CLANG_BIN_DIR")
        super().__init__(job_name=job_name)

    def _create_profdata(self, *, work_dir):
        """
        work_dir is expected to contain:
            rawprof/
        Process the raw data and leave a profdata index file
        in the working directory (e.g. usrnode.profdata)
        """
        rawprof_dir = os.path.join(os.path.abspath(work_dir), "rawprof")
        if not os.path.exists(rawprof_dir):
            file_list = []
            for name in os.listdir(work_dir):
                path = os.path.join(work_dir, name)
                if os.path.isdir(path):
                    file_list.extend(self._create_profdata(work_dir=path))
            return file_list

        size_to_files = {}
        for fname in os.listdir(rawprof_dir):
            file_path = os.path.join(rawprof_dir, fname)
            size = os.stat(file_path).st_size
            if not size:
                continue
            size_to_files.setdefault(size, []).append(file_path)

        most_size = 0
        most_files = []
        for size,files in size_to_files.items():
            if (len(most_files) < len(files)) or (len(most_files) == len(files) and most_size < size):
                most_size = size
                most_files = files

        if not most_size:
            return [] # XXXrs - should this be an exception?

        merge_files_path = os.path.join(work_dir, 'merge.files')
        with open(merge_files_path, 'w+') as f:
            for path in most_files:
                f.write("{}\n".format(path))

        profdata_path = os.path.join(work_dir, 'usrnode.profdata')
        cargs = [os.path.join(self.clang_bin_dir, "llvm-profdata"), "merge"]
        cargs.extend(["-f", merge_files_path])
        cargs.extend(["-o", profdata_path])
        self.logger.debug("run command: {}".format(cargs))
        cp = subprocess.run(cargs,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
        if cp.returncode:
            raise Exception("llvm-profdata failure creating usrnode.profdata\n{}"
                            .format(cp.stdout.decode('utf-8')))

        return [profdata_path]

    def _process_coverage(self, *, coverage_dir):
        """
        """
        usrnode_path = os.path.join(coverage_dir, 'bin', 'usrnode')
        if not os.path.exists(usrnode_path):
            raise ClangCoverageNoBinary("{} does not exist".format(usrnode_path))

        profdata_files = self._create_profdata(work_dir=coverage_dir)
        self.logger.debug("profdata_files: {}".format(profdata_files))
        if not profdata_files:
            raise ClangCoverageNoData("No non-zero rawprof files found")
        if len(profdata_files) > 1:
            # Merge all sub-profdata into a merged profdata...
            profdata_file_path = os.path.join(coverage_dir, 'merged.profdata')
            cargs = [os.path.join(self.clang_bin_dir, "llvm-profdata"), "merge"]
            for path in profdata_files:
                cargs.append(path)
            cargs.extend(["-o", profdata_file_path])
            self.logger.debug("run command: {}".format(cargs))
            cp = subprocess.run(cargs,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
            if cp.returncode:
                raise Exception("llvm-profdata failure creating merged index\n{}"
                                .format(cp.stdout.decode('utf-8')))
        else:
            profdata_file_path = profdata_files[0]
        self.logger.debug("final profdata file: {}".format(profdata_file_path))

        # Make our coverage.json
        json_file_path = os.path.join(coverage_dir, 'coverage.json')
        cargs = [os.path.join(self.clang_bin_dir, "llvm-cov"), "export", usrnode_path]
        cargs.extend(["-instr-profile", profdata_file_path])
        cargs.extend(["-format", "text"])
        self.logger.debug("run command: {}".format(cargs))
        with open(json_file_path, "w+") as fd:
            cp = subprocess.run(cargs, stdout=fd, stderr=subprocess.PIPE)
            if cp.returncode:
                raise Exception("llvm-cov failure while creating coverage.json\n{}"
                                .format(cp.stderr.decode('utf-8')))

        # Make the in-place html report
        try:
            cargs = [os.path.join(self.clang_bin_dir, "llvm-cov"), "show", usrnode_path]
            cargs.extend(["-instr-profile", profdata_file_path])
            cargs.extend(["-format", "html"])
            cargs.extend(["-output-dir", coverage_dir])
            self.logger.debug("run command: {}".format(cargs))
            cp = subprocess.run(cargs, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if cp.returncode:
                err = "llvm-cov failure: {}".format(cp.stdout.decode('utf-8'))
                raise Exception(err)
        except Exception as e:
            # Non-fatal
            self.logger.exception("failure while creating html report")



    def update_build(self, *, bnum, jbi, log):

        """
        Read the coverage.json file and convert to our preferred index form,
        filtering for only files of interest (plus totals).
        """
        coverage_file_path = os.path.join(self.artifacts_root, bnum, self.coverage_file_name)
        try:
            summaries = ClangCoverage(path=coverage_file_path).file_summaries()
        except FileNotFoundError:
            self.logger.exception("file not found: {}".format(coverage_file_path))
            return None
        except ClangCoverageEmptyFile:
            self.logger.exception("file is empty: {}".format(coverage_file_path))
            return None
        except Exception:
            self.logger.exception("exception loading: {}".format(coverage_file_path))
            raise

        data = {}
        for filename, summary in summaries.items():
            data.setdefault('coverage', {})[MongoDB.encode_key(filename)] = summary
        return data


if __name__ == '__main__':
    print("Compile check A-OK!")
    import argparse
    from pprint import pformat

    logging.basicConfig(level=logging.DEBUG,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    parser = argparse.ArgumentParser()
    parser.add_argument("--coverage_dir", help="coverage directory to process", required=True)
    args = parser.parse_args()

    agg = ClangCoverageAggregator(job_name = "FooFakeJobName",
                                  coverage_file_name = "foo_fake_file_name",
                                  artifacts_root = "/fake/root/dir")
    agg._process_coverage(coverage_dir=args.coverage_dir)
