#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

from abc import ABC, abstractmethod

import argparse
from importlib import import_module
import json
import logging
import multiprocessing
import os
import select
import shlex
import signal
import subprocess
import sys
import time

if __name__ == '__main__':
    sys.path.append(os.environ.get('XLRINFRADIR', ''))

from py_common.dlogger import DLogger, SDKMetricsDLoggerSource
from py_common.env_configuration import EnvConfiguration

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
    a ProcessManager instance.

    run() method will be sent all lines from stdout/stderr
    of the process underlying the ProcessManager instance.

    run() will be called with a multiprocess-safe output lock
    held so that any/all logging on stdout/stderr and will be safely
    merged with the main log.

    XXXrs - FUTURE - register blacklist/whitelist filters to control
            What gets sent to run()
    """
    def __init__(self):
        cfg = EnvConfiguration({'TEST_ID': {'required': True}})
        self.data_logger = DLogger(test_id=cfg.get('TEST_ID'))

    @abstractmethod
    def run(self, *, line):
        pass


class WatcherClassBase(ABC):
    """
    Base class for a "watcher" function which can be registered to
    a Hydra instance.
    """
    def __init__(self):
        cfg = EnvConfiguration({'TEST_ID': {'required': True}})
        self.data_logger = DLogger(test_id=cfg.get('TEST_ID'))

    @abstractmethod
    def run(self):
        pass


# ================
# PROCESS MANAGERS
# ================

class ProcessManagerUninitializedLockError(Exception):
    pass


class ProcessManager(ABC):
    """
    Class wrapping a parallel (sub)process.  Arranges to read
    stdout/stderr of that process and calls any registered
    "log scrapers" as needed.

    Safely merges stdout/stderr from the underlying process and
    any log scrapers into the final output log.
    """

    def __init__(self, *, frequency):

        self.logger = logging.getLogger(__name__)
        self.frequency = frequency
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
        # class instance must implement run()
        run_func = getattr(scraper, "run", None)
        if not run_func or not callable(run_func):
            raise ValueError("class instance does not implement run()")
        self.logger.debug("scraper: {}".format(scraper))
        self.scrapers.append(scraper)

    def _add_from_config(self, *, scraper_config):
        pass

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
            raise ProcessManagerUninitializedLockError("locks not initialized")
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


class PopenProcessManager(ProcessManager):
    """
    A ProcessManager controlling a sub-process started with subprocess.Popen
    """
    def __init__(self, *, cmdline, env, frequency):
        super().__init__(frequency=frequency)
        self.cmdline = cmdline
        self.subprocess = None
        self.env = env

    def sub_process_start(self):
        self.logger.debug("launching command {}".format(self.cmdline))
        args = shlex.split(self.cmdline)
        p = subprocess.Popen(args, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT,
                                   env=self.env,
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


class ForkProcessManager(ProcessManager):
    """
    A ProcessManager controlling a child sub-process started with os.fork()
    """
    def __init__(self, *, func, env, args=None, frequency):
        super().__init__(frequency=frequency)
        self.func = func
        self.env = env
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

            if self.env is not None:
                os.environ = self.env
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


class ClassManager(ForkProcessManager):
    """
    A ProcessManager wrapping a "watcher" class
    """
    def __init__(self, *, instance, env, frequency):
        # class instance must implement run()
        run_func = getattr(instance, "run", None)
        if not run_func or not callable(run_func):
            raise ValueError("class instance does not implement run()")
        super().__init__(func=run_func, env=env, frequency=frequency)


# ==================================
# HYDRA - Multiple Heads! (Watchers)
# ==================================

class HydraConfigurationError(Exception):
    pass


class Hydra(object):
    def __init__(self, *, test_id, cmd=None, cfg=None):
        self.logger = logging.getLogger(__name__)
        self.logger.debug("start")

        os.environ['TEST_ID'] = test_id
        self.data_logger = DLogger(test_id=test_id)

        self.scraper_cfg_by_name = {}
        self.watcher_cfg_by_name = {}
        self.watcher_by_name = {}

        # Output lock avoids log scrambling
        self.output_lock = multiprocessing.Lock()
        self.shutdown_event = multiprocessing.Event()

        # Orderly shutdown
        self.exit_event = multiprocessing.Event()
        self.do_shutdown = False
        self.returnstatus = 0

        if cmd:
            watcher=PopenProcessManager(cmdline=cmd, env=os.environ, frequency=None)
            # Stash this watcher under the reserved name "MAIN" so we can
            # configure scrapers for it in the configuration file.
            self.add(name="MAIN", watcher=watcher)

        if cfg:
            # See CONFIG_README.txt for configuration syntax.
            self.init_from_config(cfg=cfg)

    def _init_watcher(self, *, watcher_name, frequency):
        watcher_cfg = self.watcher_cfg_by_name.get(watcher_name, None)
        if watcher_cfg is None:
            raise HydraConfigurationError("no watcher named: {}"
                                          .format(watcher_name))
        env = watcher_cfg.get('environment', None)
        if env is not None:
            # In case we need it :)
            errstr = "invalid environment: {}".format(env)
            newenv = {}
            for eitem in env:
                target = eitem.get('target', None)
                if not target:
                    raise HydraConfigurationError(errstr)
                source = eitem.get('source', None)
                val = eitem.get('value', None)
                if source:
                    val = os.environ.get(source, None)
                if val is None:
                    raise HydraConfigurationError(errstr)
                newenv[target] = val

            self.logger.debug("newenv: {}".format(newenv))
            env = dict(os.environ, **newenv)

        if env is None:
            env = os.environ

        # env is the watcher's environment...

        watcher = None
        builtin = watcher_cfg.get('builtin', None)
        if builtin is not None:
            self.logger.debug("builtin: {}".format(builtin))
            # Built-in presumed already in-scope
            cur_env = os.environ
            os.environ = env
            watcher = ClassManager(instance=get_builtin_class(builtin),
                                   frequency=frequency,
                                   env=env)
            os.environ = cur_env

        if watcher is None:
            # Command-line
            cmdline = watcher_cfg.get('cmdline', None)
            if cmdline is not None:
                watcher = PopenProcessManager(cmdline=cmdline,
                                              frequency=frequency,
                                              env=env)

        if watcher is None:
            # Custom class
            module_path = watcher_cfg.get('module_path', None)
            class_name = watcher_cfg.get('class_name', None)
            if module_path and class_name:
                mod = import_module(module_path)
                cls = getattr(mod, class_name)()
                cur_env = os.environ
                os.environ = env
                watcher = ClassManager(instance=cls,
                                       frequency=frequency,
                                       env=env)
                os.environ = cur_env

        if watcher is None:
            raise HydraConfigurationError(
                    "invalid watcher configuration: {}"
                    .format(watcher_cfg))
        return (watcher, env)


    def _init_scraper(self, *, scraper_name, watcher_env):
        scraper_cfg = self.scraper_cfg_by_name.get(scraper_name, None)
        if scraper_cfg is None:
            raise HydraConfigurationError("no scraper named: {}"
                                          .format(scraper_name))
        scraper = None
        builtin = scraper_cfg.get('builtin', None)
        if builtin is not None:
            # Built-in presumed already in-scope
            cur_env = os.environ
            os.environ = watcher_env
            scraper = get_builtin_class(builtin)
            os.environ = cur_env

        if scraper is None:
            # Custom class
            module_path = scraper_cfg.get('module_path', None)
            class_name = scraper_cfg.get('class_name', None)
            if module_path and class_name:
                mod = import_module(module_path)
                cur_env = os.environ
                os.environ = watcher_env
                scraper = getattr(mod, class_name)()
                os.environ = cur_env

        if scraper is None:
            raise HydraConfigurationError(
                            "invalid scraper configuration: {}"
                            .format(scraper_cfg))
        return scraper

    def init_from_config(self, *, cfg):

        # See CONFIG_README.txt for configuration syntax.
        # XXXrs - FUTURE - proper schema validation

        self.logger.debug("start")
        with open(cfg, 'r') as fd:
            dikt = json.load(fd)

        self.scraper_cfg_by_name = dikt.get('scrapers', {})
        self.watcher_cfg_by_name = dikt.get('watchers', {})
        if "MAIN" in self.watcher_cfg_by_name:
            raise HydraConfigurationError("\"MAIN\" is a reserved watcher name")

        hydra_list = dikt.get('hydra', None)
        if not hydra_list:
            errstr = "missing hydra config: {}".format(dikt)
            raise HydraConfigurationError(errstr)

        for item in dikt.get('hydra', []):
            watcher_name = item.get('name', None)
            if not watcher_name:
                errstr = "hydra entry missing name: {}".format(item)
                raise HydraConfigurationError(errstr)

            self.logger.debug("watcher_name: {}".format(watcher_name))
            if watcher_name == "MAIN":
                watcher = self.watcher_by_name["MAIN"]
                watcher_env = os.environ
            else:
                frequency = item.get('frequency', None)
                watcher, watcher_env = self._init_watcher(
                                                watcher_name = watcher_name,
                                                frequency = frequency)

            for scraper_name in item.get('scrapers', []):
                scraper = self._init_scraper(scraper_name = scraper_name,
                                             watcher_env = watcher_env)
                watcher.add(scraper=scraper)

            if watcher_name != "MAIN":
                # We've already got one you see.  And it's veeery nice.
                self.add(name=watcher_name, watcher=watcher)

    def add(self, *, name, watcher):
        self.logger.debug("name: {} watcher: {}".format(name, watcher))
        if name in self.watcher_by_name:
            raise ValueError("watcher with name {} already exists".format(name))
        watcher.init_locking(output_lock = self.output_lock,
                             shutdown_event = self.shutdown_event,
                             exit_event = self.exit_event)
        self.watcher_by_name[name] = watcher

    def done(self):
        # We're done when all non-periodic watchers are done.
        # Periodic watchers (aka monitors) run indefinitely until they
        # exit, or are signaled to stop.
        self.logger.debug("start")
        for name,watcher in self.watcher_by_name.items():
            self.logger.debug("checking watcher {}:{}".format(name,watcher))
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
        for name,watcher in self.watcher_by_name.items():
            self.logger.debug("start watcher {}:{}".format(name,watcher))
            watcher.start()

        start_by = time.time()+startup_timeout
        all_started = False
        start_timeout = False
        while not all_started:
            if time.time() >= start_by:
                self.logger.error("startup timeout")
                start_timeout = True
                break

            for name,watcher in self.watcher_by_name.items():
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
        self.logger.debug("run returnstatus: {}".format(self.returnstatus))
        return self.returnstatus

    def shutdown(self, *, shutdown_timeout=60):

        self.logger.debug("start")
        give_up_at = time.time()+shutdown_timeout

        self.logger.debug("set shutdown event")
        self.shutdown_event.set()

        for name,watcher in self.watcher_by_name.items():
            time_left = give_up_at - time.time()
            if time_left < 1:
                self.logger.error("shutdown timeout")
                break
            watcher.join(timeout=time_left)


# BUILT-IN CLASSES ==========
# Built-ins are here now, but in future they may need to move to
# their own space(s).  If/when that happens, will need to import here.
#
# All watcher/scraper classes initialize from the environment.
# Nothing is passed to __init__()

def get_builtin_class(classname):
    """
    Factory returning a built-in class.
    """
    cls = globals()[classname]
    return cls()


# SCRAPER CLASSES ==========
# None yet


# WATCHER CLASSES ==========


class SDKMetricsWatcher(WatcherClassBase):
    """
    Uses an SDK client and SDKMetricsDLoggerSource to log cluster metrics.
    """
    def __init__(self):

        cfg = EnvConfiguration({'TEST_ID': {'required': True},
                                'HOST': {'required': True},
                                'PORT': {'default': 442, 'type': EnvConfiguration.NUMBER},
                                'USER': {'default': 'admin'},
                                'PASS': {'default': 'admin'},
                                'NODE': {'default': 0, 'type': EnvConfiguration.NUMBER},
                                'METRICS_GROUP_PATS': {'required': False},
                                'METRICS_NAME_PATS': {'required': False}})

        super().__init__()
        self.logger = logging.getLogger(__name__)
        self.logger.info("STARTING")

        self.host = cfg.get('HOST')
        self.port = cfg.get('PORT')
        self.user = cfg.get('USER')
        self.passwd = cfg.get('PASS')
        self.node = cfg.get('NODE')
        self.group_pats = cfg.get('METRICS_GROUP_PATS', None)
        self.name_pats = cfg.get('METRICS_NAME_PATS', None)

        self.xcalar_url = "https://{}:{}".format(self.host, self.port)
        self.client_secrets = {'xiusername': self.user, 'xipassword': self.passwd}
        self.xcalar_api = XcalarApi(url=self.xcalar_url, client_secrets=self.client_secrets)
        self.client = Client(url=self.xcalar_url, client_secrets=self.client_secrets)

        self.monitor_name = "XcalarCluster_{}".format(self.host)
        source = SDKMetricsDLoggerSource(name=self.monitor_name,
                                         client=self.client,
                                         node=self.node)
        self.data_logger.register_source(source=source)

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

    logger = logging.getLogger(__name__)
    hydra = None

    def shutdown_hydra(signum, frame):
        """
        Arrange for orderly shutdown on signal.
        """
        if hydra:
            hydra.do_shutdown = True

    signal.signal(signal.SIGINT, shutdown_hydra)
    signal.signal(signal.SIGHUP, shutdown_hydra)
    signal.signal(signal.SIGTERM, shutdown_hydra)

    parser = argparse.ArgumentParser()
    parser.add_argument("--cmd", help="command-line for primary process", required=False)
    parser.add_argument("--cfg", help="path to hydra configuration file", required=False)
    parser.add_argument("--test_id", help="test identifier", required=False)
    args = parser.parse_args()

    if not args.cmd and not args.cfg:
        raise ValueError("at least one of --cmd or --cfg must be supplied")

    test_id = args.test_id

    # If test_id not supplied, manufacture one from (presumed)
    # jenkins job name and build number environment variables.
    if not test_id:
        jenkins_job = os.environ.get('JOB_NAME', None)
        jenkins_build = os.environ.get('BUILD_NUMBER', None)
        if jenkins_job and jenkins_build:
            test_id = "jenkins:{}:{}".format(jenkins_job, jenkins_build)
    if not test_id:
        test_id = 'NotSupplied'

    hydra = Hydra(test_id=test_id, cmd=args.cmd, cfg=args.cfg)
    hydra.run()
