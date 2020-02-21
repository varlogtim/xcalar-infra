#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.


from abc import ABC, abstractmethod

import argparse
import logging
import multiprocessing
import os
import select
import shlex
import signal
import subprocess
import sys
import time

from py_common.dlogger import DLogger, SDKMetricsDLoggerSource

from xcalar.external.LegacyApi.XcalarApi import XcalarApi
from xcalar.external.client import Client

os.environ["XLR_PYSDK_VERIFY_SSL_CERT"] = "false"

# Configure logging
logging.basicConfig(level=logging.DEBUG,
                    format="'%(asctime)s - %(levelname)s - %(threadName)s - %(funcName)s - %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout)])


class LogScraperBase(ABC):
    """
    Base class for a "log scraper" function which can be registered to
    a ProcessWatcher instance.

    run() method will be sent all lines from stdout/stderr
    of the process underlying the ProcessWatcher instance.

    run() will be called with a multiprocess-safe output lock
    held so that any/all logging on stdout/stderr and will be safely
    merged with the main log.

    XXXrs - FUTURE - register blacklist/whitelist filters to control
            What gets sent to run()
    """
    def __init__(self, *, test_id):
        self.data_logger = DLogger(test_id=test_id)

    @abstractmethod
    def run(self, *, line):
        pass

class WatcherClassBase(ABC):
    """
    Base class for a "watcher" function which can be registered to
    a Hydra instance.

    run() method
    """
    def __init__(self, *, test_id):
        self.data_logger = DLogger(test_id=test_id)

    @abstractmethod
    def run(self):
        pass


# ================
# PROCESS WATCHERS
# ================

class ProcessWatcherUninitializedLockError(Exception):
    pass


class ProcessWatcher(ABC):
    """
    Class wrapping a parallel (sub)process.  Arranges to read
    stdout/stderr of that process and calls any registered
    "log scrapers" as needed.

    Safely merges stdout/stderr from the underlying process and
    any log scrapers into the final output log.
    """

    def __init__(self, *, frequency = None, scrapers = None):

        self.logger = logging.getLogger(__name__)
        self.frequency = frequency
        if scrapers is not None:
            self.scrapers = scrapers
        else:
            self.scrapers = []
        self.launcher_process = None
        self.output_lock = None
        self.shutdown_event = None
        self.exit_event = None
        self.started = False
        self.returnstatus = None

    def init_locking(self, *, output_lock, shutdown_event, exit_event):
        self.output_lock = output_lock
        self.shutdown_event = shutdown_event
        self.exit_event = exit_event

    def add(self, *, scraper):
        self.logger.debug("scraper: {}".format(scraper))
        self.scrapers.append(scraper)

    @abstractmethod
    def sub_process_start(self):
        """
        Called to launch the appropriate sub-process.

        Return an object connected to the sub-process
        stdin/stdout and implementing readline()
        """
        pass

    @abstractmethod
    def sub_process_stop(self, *, signum):
        """
        Called to stop any running sub-process.
        """
        pass

    def _process_line(self, *, line):
        # output only under lock to avoid possible intermingling
        # of lines (and possible corruption of structured content)
        self.logger.debug("start")
        with self.output_lock:
            self.logger.debug("emit line")
            print(line, end='')
        for scraper in self.scrapers:
            self.logger.debug("calling scraper: {}".format(scraper))
            # Hold the lock in case some log scraper wants to
            # log something too...
            with self.output_lock:
                # XXXrs - label the line with a source?
                scraper.run(line=line)

    def _subprocess_reader(self, *, final_pass=False):
        """
        Start our sub-process appropriately, and read lines from its
        stdout/stderr until it's done (exits) or we're shut down.
        """
        self.logger.debug("start")
        r = self.sub_process_start()
        poll = select.poll()
        self.logger.debug("poll register {}".format(r))
        poll.register(r, select.POLLIN|select.POLLPRI)

        while final_pass or not self.shutdown_event.is_set():
            self.logger.debug("poll/readline start")
            poll_result = poll.poll(1000)
            if not poll_result:
                self.logger.debug("poll timeout")
                continue # go see if we're shutdown

            self.logger.debug("poll returns: {}".format(poll_result))
            line = r.readline() # XXXrs could block if no "\n" :(
            self.logger.debug("readline returns")

            if line:
                self._process_line(line=line)
                continue

            self.logger.debug("child process gone")
            r.close()
            self.returnstatus = self.sub_process_status()
            self.logger.debug("{} returnstatus {}".format(self, self.returnstatus))
            return # underlying child is gone

        # buh bye!
        r.close()
        self.logger.debug("saw shutdown event")
        self.sub_process_stop()
        self.logger.debug("end")

    def _subprocess_launcher(self):
        """
        Handle single-shot or periodic sub-process
        """
        self.logger.debug("start")

        while not self.shutdown_event.is_set():
            self._subprocess_reader()
            if not self.frequency:
                self.logger.debug("{} returnstatus {}"
                                  .format(self, self.returnstatus))
                sys.exit(self.returnstatus)
            if not self.shutdown_event.wait(timeout=self.frequency):
                # Timeout
                continue

        # event triggered...
        self.logger.debug("shutdown event set")
        if self.exit_event.is_set():
            # On normal exit, we do a final pass if we're periodic
            if self.frequency:
                self.logger.debug("final pass")
                self._subprocess_reader(final_pass=True)
        self.logger.debug("{} returnstatus {}"
                          .format(self, self.returnstatus))
        sys.exit(self.returnstatus)

    def start(self):
        self.logger.debug("start")
        if not self.output_lock or not self.shutdown_event or not self.exit_event:
            raise ProcessWatcherUninitializedLockError("locks not initialized")
        p = multiprocessing.Process(target=self._subprocess_launcher)
        p.daemon = True # hygineic :)
        p.start()
        self.launcher_process = p

        self.started = True
        self.logger.debug("end")

    def join(self, *, timeout=0):
        self.logger.debug("join launcher_process")
        if not self.launcher_process:
            self.logger.debug("no launcher_process")
            return
        # Return code?
        self.launcher_process.join(timeout=timeout)
        if self.launcher_process.is_alive():
            self.logger.error("timeout")
        else:
            self.returnstatus = self.launcher_process.exitcode
            self.logger.debug("launcher_process returnstatus {}"
                              .format(self.returnstatus))
        self.launcher_process = None

    def is_alive(self):
        return self.launcher_process and self.launcher_process.is_alive()


class SubprocessWatcher(ProcessWatcher):
    """
    A ProcessWatcher wrapping a sub-process started with subprocess.Popen
    """
    def __init__(self, *, cmdline, frequency=None, scrapers=None):
        super().__init__(frequency=frequency, scrapers=scrapers)
        self.cmdline = cmdline
        self.subprocess = None

    def sub_process_start(self):
        self.logger.debug("launching command {}".format(self.cmdline))
        args = shlex.split(self.cmdline)
        p = subprocess.Popen(args, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT,
                                   universal_newlines=True,
                                   bufsize=0)
        self.subprocess = p
        return p.stdout

    def sub_process_status(self):
        self.logger.debug("status for {}".format(self))
        self.subprocess.wait()
        return self.subprocess.returncode

    def sub_process_stop(self):
        self.logger.debug("start")
        if not self.subprocess:
            self.logger.debug("no subprocess running")
            return
        self.logger.debug("signal subprocess with SIGTERM")
        self.subprocess.send_signal(signal.SIGTERM)
        self.subprocess = None
        self.logger.debug("end")


class Unbuffered(object):
    def __init__(self, stream):
        self.stream = stream
    def write(self, data):
        self.stream.write(data)
        self.stream.flush()
    def writelines(self, datas):
        self.stream.writelines(datas)
        self.stream.flush()
    def __getattr__(self, attr):
        return getattr(self.stream, attr)


class ForkedProcessWatcher(ProcessWatcher):
    """
    A ProcessWatcher wrapping a child sub-process started with os.fork()
    """
    def __init__(self, *, func, args=None, frequency=None, scrapers=None):
        super().__init__(frequency=frequency, scrapers=scrapers)
        self.func = func
        self.args = args
        self.pid = None

    def sub_process_start(self):
        self.logger.debug("launching child function {}:{}"
                          .format(self.func, self.args))

        p_read, p_write = os.pipe()
        self.pid = os.fork()
        if not self.pid:
            unbuf = Unbuffered(os.fdopen(p_write, 'w'))
            os.dup2(unbuf.fileno(), sys.stdout.fileno())
            os.dup2(unbuf.fileno(), sys.stderr.fileno())

            # Anything written to stdout/stderr from this point on goes
            # through the pipe to the parent and is processed...

            if self.args:
                ec = self.func(**(self.args))
            else:
                ec = self.func()
            #sys.stdout.flush()
            #sys.stderr.flush()
            if ec is None:
                ec = 0 # um....
            sys.exit(ec)

        # Parent process
        self.logger.debug("started child process {}".format(self.pid))
        os.close(p_write)
        return os.fdopen(p_read)

    def sub_process_status(self):
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if not pid:
            self.logger.error("pid {} still running")
            return None
        if os.WIFSIGNALED(status):
            self.logger.error("pid {} was signaled")
        if not os.WIFEXITED(status):
            self.logger.error("pid {} did not exit")
            return None
        self.logger.debug("status for {}".format(self))
        return os.WEXITSTATUS(status)

    def sub_process_stop(self):
        self.logger.debug("start")
        if self.pid is None:
            self.logger.debug("no child process running")
            return
        self.logger.debug("kill child process pid {} signal SIGTERM".format(self.pid))
        os.kill(self.pid, signal.SIGTERM)
        time.sleep(1)
        self.logger.debug("collect pid {}".format(self.pid))
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if not pid:
            self.logger.debug("pid {} still not stopped, send SIGTERM again".format(self.pid))
            os.kill(self.pid, signal.SIGTERM)
            time.sleep(10)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if not pid:
                self.logger.debug("pid {} STILL not stopped, send SIGKILL".format(self.pid))
                os.kill(self.pid, signal.SIGKILL)
                self.logger.debug("wait for pid {}".format(self.pid))
                pid, status = os.waitpid(self.pid, 0)
        self.logger.debug("os.waitpid returns pid {} status {}".format(pid, status))
        self.pid = None
        self.logger.debug("end")


class WatcherClassWatcher(ForkedProcessWatcher):
    """
    A ProcessWatcher wrapping a WatcherClass (class with a run() method)
    """
    def __init__(self, *, instance, frequency=None, scrapers=None):
        # class instance must implement run()
        run_func = getattr(instance, "run", None)
        if not run_func or not callable(run_func):
            raise ValueError("class instance does not implement run_func()")
        super().__init__(func=run_func, frequency=frequency, scrapers=scrapers)


# ==================================
# HYDRA - Multiple Heads! (Watchers)
# ==================================

class Hydra(object):
    def __init__(self, *, test_id):
        self.logger = logging.getLogger(__name__)
        self.logger.debug("start")

        self.test_id = test_id
        self.data_logger = DLogger(test_id=self.test_id)
        self.watchers = []

        # Output lock avoids log scrambling
        self.output_lock = multiprocessing.Lock()
        self.shutdown_event = multiprocessing.Event()
        self.exit_event = multiprocessing.Event()
        self.do_shutdown = False
        self.returnstatus = 0

    def add(self, *, watcher):
        self.logger.debug("watcher: {}".format(watcher))
        watcher.init_locking(output_lock = self.output_lock,
                             shutdown_event = self.shutdown_event,
                             exit_event = self.exit_event)
        self.watchers.append(watcher)

    def done(self):
        # We're done when all non-periodic watchers are done.
        # Periodic watchers (aka monitors) run indefinitely until told to stop.
        self.logger.debug("start")
        for watcher in self.watchers:
            self.logger.debug("checking watcher {}".format(watcher))
            if not watcher.frequency:
                if watcher.is_alive():
                    self.logger.debug("return False")
                    return False
                watcher.join()
                status = watcher.returnstatus
                self.logger.debug("non-periodic watcher returnstatus {}".format(status))
                if status:
                    self.returnstatus = status

        self.logger.debug("return True")
        return True

    def run(self, *, startup_timeout=60, shutdown_timeout=60):
        self.logger.debug("start")
        for watcher in self.watchers:
            self.logger.debug("start watcher {}".format(watcher))
            watcher.start()

        start_by = time.time()+startup_timeout
        all_started = False
        start_timeout = False
        while not all_started:
            if time.time() >= start_by:
                self.logger.error("startup timeout")
                start_timeout = True
                break

            for watcher in self.watchers:
                if not watcher.started:
                    self.logger.debug("all watchers NOT started")
                    time.sleep(0.1)
                    break
            else:
                self.logger.debug("all watchers started")
                all_started = True

        while not start_timeout and not self.do_shutdown:
            if self.done():
                # Indicate shutting down due to "normal" exit
                self.exit_event.set()
                break
            time.sleep(1)

        self.shutdown(shutdown_timeout=shutdown_timeout)
        uelf.logger.debug("run returnstatus: {}".format(self.returnstatus))
        return self.returnstatus

    def shutdown(self, *, shutdown_timeout=60):

        self.logger.debug("start")
        give_up_at = time.time()+shutdown_timeout

        self.logger.debug("set shutdown event")
        self.shutdown_event.set()

        for watcher in self.watchers:
            time_left = give_up_at - time.time()
            if time_left < 1:
                self.logger.error("shutdown timeout")
                break
            watcher.join(timeout=time_left)

# BUILT-IN WATCHER CLASSES ==========

class SDKMetricsWatcher(WatcherClassBase):
    """
    Monitor that initializes an SDK client and SDKMetricsDLoggerSource
    and uses it to log cluster metrics.
    """
    def __init__(self, *, host, port, user, password, test_id,
                          node = 0, group_by = None,
                          metrics_group_pats = None,
                          metrics_name_pats = None):
        super().__init__(test_id=test_id)
        self.logger = logging.getLogger(__name__)
        self.logger.info("STARTING")
        self.xcalar_url = "https://{}:{}".format(host, port)
        self.client_secrets = {'xiusername': user, 'xipassword': password}
        self.xcalar_api = XcalarApi(url=self.xcalar_url, client_secrets=self.client_secrets)
        self.client = Client(url=self.xcalar_url, client_secrets=self.client_secrets)

        self.monitor_name = "XcalarCluster_{}".format(host)
        source = SDKMetricsDLoggerSource(name=self.monitor_name, client=self.client,
                                         node=node, group_by=group_by)
        self.data_logger.register_source(source=source)
        self.group_pats = metrics_group_pats
        self.name_pats = metrics_name_pats

    def _match_pats(self, *, s, pats):
        for pat in pats:
            if pat.match(s):
                return True
        return False

    def run(self):
        log_entry = self.data_logger.log(data_type="XCALAR_STATS",
                                         data_label="MONITOR_CHECKPOINT",
                                         detail=True)

        # For human consumption...
        if not self.group_pats and not self.name_pats:
            return

        metrics = log_entry.metrics(source_name=self.monitor_name)
        for name,info in metrics.items():
            if self.name_pats and not self._match_pats(s=name, pats=self.name_pats):
                continue
            group = info.get('group_name', None)
            if group and self.group_pats and not self._match_pats(s=group, pats=self.group_pats):
                continue
            self.logger.info("{} {} {}".format(group, name, info['metric_value']))


if __name__ == '__main__':

    # XXXrs - FUTURE - This is a "toy" command interface now.
    #                  Needs fleshing out.

    logger = logging.getLogger(__name__)

    hydra = None
    def shutdownHydra(signum, frame):
        if hydra:
            hydra.do_shutdown = True

    signal.signal(signal.SIGINT, shutdownHydra)
    signal.signal(signal.SIGHUP, shutdownHydra)
    signal.signal(signal.SIGTERM, shutdownHydra)

    parser = argparse.ArgumentParser()
    parser.add_argument("-c", dest='commands', action='append',
                        help="cmdline[:frequency] command and optional frequency."
                             " May be called multiple times to run multiple sub-commands.")
    parser.add_argument("-i", dest='test_id', help="Test identifier")
    args = parser.parse_args()

    test_id = args.test_id

    # If test_id not supplied, manufacture one from
    # jenkins job name and build number environment variables.
    if not test_id:
        jenkins_job = os.environ.get('JOB_NAME', None)
        jenkins_build = os.environ.get('BUILD_NUMBER', None)
        if jenkins_job and jenkins_build:
            test_id = "jenkins:{}:{}".format(jenkins_job, jenkins_build)
    if not test_id:
        test_id = 'NotSupplied'

    hydra = Hydra(test_id=test_id)
    if args.commands:
        for cmd in args.commands:
            fields = cmd.split(':')
            if len(fields) > 1:
                sw = SubprocessWatcher(cmdline=fields[0], frequency=int(fields[1]))
            else:
                sw = SubprocessWatcher(cmdline=fields[0])
            hydra.add(watcher=sw)

    hydra.run()
