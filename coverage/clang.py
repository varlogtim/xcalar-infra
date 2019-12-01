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
import pprint
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

class ClangCoverageFile(object):

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

class ClangCoverageDir(object):

    local_clang_dir = "/usr/local/bin/clang"
    clang_bin_default = "/opt/clang5/bin"

    if os.path.exists(local_clang_dir):
        if os.path.islink(local_clang_dir):
            clang_bin_default = os.readlink(local_clang_dir)
        else:
            clang_bin_default = local_clang_dir

    print("clang_bin_default: {}".format(clang_bin_default))
    ENV_PARAMS = {"CLANG_BIN_DIR": {"default": clang_bin_default},
                  "CLANG_RAWPROF_DIR_NAME": {"default": "rawprof"},
                  "CLANG_USER_BIN_DIR_NAME": {"default": "bin"}}

    CFG = EnvConfiguration(ENV_PARAMS)
    CLANG_BIN_DIR = CFG.get("CLANG_BIN_DIR")

    def __init__(self, *, coverage_dir, bin_name="usrnode", profdata_file_name="usrnode.profdata"):
        self.logger = logging.getLogger(__name__)
        self.coverage_dir = coverage_dir
        self.bin_name = bin_name
        self.profdata_file_name = profdata_file_name

    def bin_path(self):
        return os.path.join(self.coverage_dir,
                            ClangCoverageDir.CFG.get("CLANG_USER_BIN_DIR_NAME"),
                            self.bin_name)

    def profdata_path(self):
        return os.path.join(self.coverage_dir, self.profdata_file_name)

    def _create_profdata(self, *, work_dir, force):
        """
        work_dir is expected to have a "raw profile data" directory
        (named by CLANG_RAWPROF_DIR_NAME).

        Process the raw data and leave a profdata index file
        in the working directory (e.g. usrnode.profdata)
        """
        self.logger.debug("start work_dir {} force {}".format(work_dir, force))
        profdata_path = os.path.join(work_dir, self.profdata_file_name)
        self.logger.debug("profdata_path: {}".format(profdata_path))
        if os.path.exists(profdata_path) and not force:
            self.logger.info("{} exists and not force, skipping...".format(profdata_path))
            return [profdata_path]

        rawprof_dir = os.path.join(work_dir, ClangCoverageDir.CFG.get("CLANG_RAWPROF_DIR_NAME"))
        self.logger.debug("rawprof_dir: {}".format(rawprof_dir))
        if not os.path.exists(rawprof_dir):
            self.logger.debug("{} doesn't exist".format(rawprof_dir))
            file_list = []
            for name in os.listdir(work_dir):
                path = os.path.join(work_dir, name)
                if os.path.isdir(path):
                    file_list.extend(self._create_profdata(work_dir=path, force=force))
            return file_list

        self.logger.debug("{} exists".format(rawprof_dir))
        size_to_files = {}
        for fname in os.listdir(rawprof_dir):
            file_path = os.path.join(rawprof_dir, fname)
            size = os.stat(file_path).st_size
            if not size:
                self.logger.debug("{} empty, skipping...".format(file_path))
                continue
            size_to_files.setdefault(size, []).append(file_path)

        self.logger.debug("size_to_files: {}".format(pprint.pformat(size_to_files)))
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

        cargs = [os.path.join(ClangCoverageDir.CLANG_BIN_DIR, "llvm-profdata"), "merge"]
        cargs.extend(["-f", merge_files_path])
        cargs.extend(["-o", profdata_path])
        self.logger.debug("run: {}".format(cargs))
        cp = subprocess.run(cargs,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
        if cp.returncode:
            raise Exception("llvm-profdata failure creating usrnode.profdata\n{}"
                            .format(cp.stdout.decode('utf-8')))
        return [profdata_path]

    @classmethod
    def _create_json(cls, *, out_dir, bin_path, profdata_path, force):
        logger = logging.getLogger(__name__)
        logger.debug("start")

        json_file_path = os.path.join(out_dir, 'coverage.json')
        if os.path.exists(json_file_path) and not force:
            logger.info("{} exists and not force, skipping...".format(json_file_path))
            return

        cargs = [os.path.join(ClangCoverageDir.CLANG_BIN_DIR, "llvm-cov"), "export", bin_path]
        cargs.extend(["-instr-profile", profdata_path])
        cargs.extend(["-format", "text"])
        logger.debug("run: {}".format(cargs))
        with open(json_file_path, "w+") as fd:
            cp = subprocess.run(cargs, stdout=fd, stderr=subprocess.PIPE)
            if cp.returncode:
                raise Exception("llvm-cov failure while creating coverage.json\n{}"
                                .format(cp.stderr.decode('utf-8')))

    @classmethod
    def _create_html(cls, *, out_dir, bin_path, profdata_path, force):
        logger = logging.getLogger(__name__)
        logger.debug("start")

        html_path = os.path.join(out_dir, "index.html")
        if os.path.exists(html_path) and not force:
            logger.info("{} exists and not force, skipping...".format(html_path))
            return

        cargs = [os.path.join(ClangCoverageDir.CLANG_BIN_DIR, "llvm-cov"), "show", bin_path]
        cargs.extend(["-instr-profile", profdata_path])
        cargs.extend(["-format", "html"])
        cargs.extend(["-output-dir", out_dir])
        logger.debug("run: {}".format(cargs))
        cp = subprocess.run(cargs, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if cp.returncode:
            err = "llvm-cov failure: {}".format(cp.stdout.decode('utf-8'))
            raise Exception(err)

    @classmethod
    def _merge_profdata(cls, *, profdata_files, profdata_path, force):
        """
        Merge profdata files
        """
        logger = logging.getLogger(__name__)

        if os.path.exists(profdata_path) and not force:
            logger.info("{} exists and not force, skipping...".format(profdata_path))
            return

        cargs = [os.path.join(ClangCoverageDir.CLANG_BIN_DIR, "llvm-profdata"), "merge"]
        for path in profdata_files:
            cargs.append(path)
        cargs.extend(["-o", profdata_path])
        logger.debug("run command: {}".format(cargs))
        cp = subprocess.run(cargs,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
        if cp.returncode:
            raise Exception("llvm-profdata failure creating merged index\n{}"
                            .format(cp.stdout.decode('utf-8')))

    def process(self, *, force=False, create_json=True, create_html=True):
        """
        Process coverage data in our directory.
        """
        bin_path = self.bin_path()
        if not os.path.exists(bin_path):
            raise ClangCoverageNoBinary("{} does not exist".format(bin_path))

        profdata_files = self._create_profdata(work_dir=self.coverage_dir, force=force)
        self.logger.debug("profdata_files: {}".format(profdata_files))
        if not profdata_files:
            raise ClangCoverageNoData("No valid rawprof files found")

        profdata_path = os.path.join(self.coverage_dir, self.profdata_file_name)

        if len(profdata_files) > 1:
            # Merge all sub-profdata...
            ClangCoverageDir._merge_profdata(profdata_files=profdata_files,
                                             profdata_path=profdata_path,
                                             force=force)
        else:
            assert(profdata_files[0] == profdata_path)
        self.logger.debug("final instr-profile file: {}".format(profdata_path))

        # coverage.json
        if create_json:
            self._create_json(out_dir=self.coverage_dir,
                              bin_path=bin_path,
                              profdata_path=profdata_path,
                              force=force)

        # HTML
        if create_html:
            self._create_html(out_dir=self.coverage_dir,
                              bin_path=bin_path,
                              profdata_path=profdata_path,
                              force=force)

    @classmethod
    def merge(cls, *, dirs,
                      out_dir,
                      bin_name="usrnode",
                      profdata_file_name="usrnode.profdata",
                      force=False,
                      create_json=True,
                      create_html=True):
        """
        Merge coverage from multiple directories into specified
        output directory.
        """
        logger = logging.getLogger(__name__)

        if len(dirs) < 1:
            raise ValueError("dirs list must contain at least one path")

        profdata_files = []
        bin_path = None
        for path in dirs:
            logger.debug("processing {}".format(path))
            cdir = cls(coverage_dir=path,
                       bin_name=bin_name,
                       profdata_file_name=profdata_file_name)
            cdir.process(force=force,
                         create_json=create_json,
                         create_html=create_html)
            # First binary encountered will be used for the final merge...
            if not bin_path:
                bin_path = cdir.bin_path()
            profdata_files.append(cdir.profdata_path())

        if not bin_path:
            raise ClangCoverageNoBinary("no bin_path returned")

        if not profdata_files:
            raise ClangCoverageNoData("No profdata files found")

        profdata_path = os.path.join(out_dir, profdata_file_name)

        cls._merge_profdata(profdata_files=profdata_files,
                            profdata_path=profdata_path,
                            force=True) # Always re-create output files
        # coverage.json
        if create_json:
            cls._create_json(out_dir=out_dir,
                             bin_path=bin_path,
                             profdata_path=profdata_path,
                             force=True) # Always re-create output files

        # HTML
        if create_html:
            cls._create_html(out_dir=out_dir,
                             bin_path=bin_path,
                             profdata_path=profdata_path,
                             force=True) # Always re-create output files


class ClangCoverageAggregator(JenkinsAggregatorBase):

    def __init__(self, *, job_name,
                          coverage_file_name,
                          artifacts_root):

        self.logger = logging.getLogger(__name__)
        self.coverage_file_name = coverage_file_name
        self.artifacts_root = artifacts_root
        super().__init__(job_name=job_name)

    def update_build(self, *, bnum, jbi, log):
        """
        Read the coverage.json file and convert to our preferred index form,
        filtering for only files of interest (plus totals).
        """
        coverage_file_path = os.path.join(self.artifacts_root, bnum, self.coverage_file_name)
        try:
            summaries = ClangCoverageFile(path=coverage_file_path).file_summaries()
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
    cfg = EnvConfiguration({"LOG_LEVEL": {"default": logging.INFO}})
    logging.basicConfig(level=cfg.get("LOG_LEVEL"),
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)

    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", help="coverage directory to process",
                        dest='coverage_dirs', action='append', required=True)
    parser.add_argument("--out", help="output directory to store merged results",
                        required=True)
    parser.add_argument("--force", help="force re-creation of all files", action='store_true')
    args = parser.parse_args()

    ClangCoverageDir.merge(dirs=args.coverage_dirs, out_dir=args.out, force=args.force)
