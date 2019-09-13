#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import json
import logging
from matplotlib.backends.backend_pdf import PdfPages
import matplotlib.pyplot as plt
import numpy as np
import os
import re
import sys

sys.path.append(os.environ.get('XLRINFRADIR', ''))
from py_common.env_configuration import EnvConfiguration

class SqlPerfPlot(object):
    qStartKey = 'queryStart'
    qEndKey = 'queryEnd'
    fStartKey = 'fetchStart'
    fEndKey = 'fetchEnd'

    def __init__(self, *, path, is_spark=False):
        self.logger = logging.getLogger(__name__)
        self.rlist = []
        self.data = None
        self.dataByQ = {}
        self.is_spark = is_spark
        self.loadData(path=path)
        if self.is_spark:
            self.backend = 'spark'
        else:
            self.backend = 'xcalar'

        self.calcStats()

    def loadData(self, *, path):
        with open(path, 'r') as fh:
            self.data = json.load(fh)

        for tnum, queryStats in self.data['threads'].items():
            for q in queryStats:
                qname = q[0]['qname']
                if qname not in self.dataByQ:
                    self.dataByQ[qname] = []

                self.dataByQ[qname].append(q[0])

        self.numUsers = len(self.data['threads'])
        self.notes = self.data['notes'].split(',')
        self.verStr = re.match(r'.*\(version=\'xcalar-(.*)-.*', self.data['xlrVersion']).group(1)
        self.ds = os.path.basename(os.path.abspath(self.data['dataSource']['dataSource']))

    def calcStats(self):
        def natSort(s, nsre=re.compile('([0-9]+)')):
            return [int(t) if t.isdigit() else t.lower() for t in nsre.split(s)]

        self.qAvg = []
        self.qStd = []
        self.qNames = sorted(self.dataByQ.keys(), key=natSort)
        # for qname, statsList in sorted(self.dataByQ.items(), key=natSort):
        for qname in self.qNames:
            statsList = self.dataByQ[qname]
            qtime = []
            for stat in statsList:
                stat = stat[self.backend]
                qtime.append(stat[self.fEndKey] - stat[self.qStartKey])
            self.qAvg.append(np.mean(qtime))
            self.qStd.append(np.std(qtime))

    def getNextSlot(self, *, rlist, endRange, minSpace = 0.5):
        for i in range(len(rlist)):
            if rlist[i][self.backend][self.qStartKey] == 0 and rlist[i][self.backend][self.qEndKey] == 0:
                rlist.pop(i)
                continue

            if rlist[i][self.backend][self.qStartKey] > endRange + minSpace:
                return rlist.pop(i)

        return None

    def getSlots(self, *, rlistIn):
        slotList = []
        rlist = list(rlistIn)
        rlist.sort(key=lambda x: x[self.backend][self.qStartKey])
        while rlist:
            endRange = -sys.maxsize
            currSlot = []
            while True:
                r = self.getNextSlot(rlist=rlist, endRange=endRange)
                if not r:
                    break
                currSlot.append(r)
                endRange = r[self.backend][self.fEndKey]

            slotList.append(currSlot)

        return slotList

    def plotIntervals(self, *, padding=0, groupWidth=1.0):
        groupNum = 1
        fig = plt.figure(figsize=(8.5, 11))
        totalTime = self.data['endEpoch'] - self.data['startEpoch']
        for qname in self.qNames:
            statsList = self.dataByQ[qname]
            slots = self.getSlots(rlistIn=statsList)
            numSlots = len(slots)
            assert(padding < groupWidth)
            startY = groupNum - groupWidth / 2
            y = startY + padding / 2
            slotWidth = (groupWidth - padding) / numSlots
            for slot in slots:
                for r in slot:
                    qStart = r[self.backend][self.qStartKey] - self.data['startEpoch']
                    qEnd = r[self.backend][self.fEndKey] - self.data['startEpoch']
                    plt.hlines(y, qStart, qEnd, color='b', lw=0.5)

                y += slotWidth
                plt.hlines(groupNum + groupWidth / 2.0, 0, totalTime, color='r', linestyles='dotted', lw=0.5)
            groupNum += 1

        ylim = (0, len(self.qNames) + 1)
        ax = plt.gca()
        ax.xaxis.grid(True)
        ax.grid(which='major', axis='x', linestyle='--')

        plt.title('{} SQL Parallelism\n{} Users, {} Nodes of {}, {}, {}'.format(self.backend, self.numUsers, self.notes[0], self.notes[1], self.verStr, self.ds))
        plt.xlabel("Time (s)")
        plt.ylabel("Query")
        plt.xlim(0, totalTime)
        plt.ylim(ylim)
        plt.yticks(np.arange(1, ylim[1]), self.qNames)

        return fig

    def plotAvg(self, *, b2_path, is_spark):
        if True: # XXXrs - Really?!?
            prevPlt = SqlPerfPlot(path=b2_path, is_spark=is_spark)
            fig, ax = plt.subplots(figsize=(8.5, 5))
            N=len(self.qAvg)
            ind = np.arange(N)    # the x locations for the groups
            width = 0.35         # the width of the bars
            p0 = ax.bar(range(len(self.qAvg)), self.qAvg, width, yerr=self.qStd)
            r = [x + width for x in range(len(prevPlt.qAvg))]
            p1 = ax.bar(r, prevPlt.qAvg, width, yerr=prevPlt.qStd)
        else:
            fig = plt.figure(figsize=(8.5, 5))
            plt.bar(range(len(self.qAvg)), self.qAvg, yerr=self.qStd)

        if is_spark:
            ax.legend((p0[0], p1[0]), ('Xcalar', 'Spark'))
        else:
            ax.legend((p0[0], p1[0]), ('Current', 'Previous'))

        plt.xticks(np.arange(len(self.qNames)), self.qNames, rotation=-90)
        plt.title('SQL Mean Execution Time w/Stddev\n{} Users, {} Nodes of {}, {}, {}'
                .format(self.numUsers, self.notes[0], self.notes[1], self.verStr, self.ds))
        plt.xlabel('Query')
        plt.ylabel('Mean Execution+Fetch Time (s)')

        return fig


class SqlPerfComparisonPdf(object):

    # N.b: The PDF_PAT must be manually coordinated with the Grafana
    #      dashboard's link URL definition :/
    ENV_PARAMS = {"SQL_PERF_COMPARISON_PDF_PAT": {"default": "/netstore/qa/sqlPerfCompare/{}_{}_{}.pdf"},
                  "SQL_PERF_ARTIFACTS_ROOT": {"default": "/netstore/qa/jenkins"},
                  "SQL_PERF_JOB_NAME": {"default": "SqlScaleTest"} } 
    
    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.path_cache = {}
        cfg = EnvConfiguration(SqlPerfComparisonPdf.ENV_PARAMS)
        self.pdf_pat = cfg.get('SQL_PERF_COMPARISON_PDF_PAT')
        self.artifacts_root = cfg.get('SQL_PERF_ARTIFACTS_ROOT')
        self.job_name = cfg.get('SQL_PERF_JOB_NAME')
        self.input_root = os.path.join(self.artifacts_root, self.job_name)

    def _cache_key(self, *, test_group, bnum1, bnum2):
        return "{}:{}:{}".format(test_group, bnum1, bnum2)

    def _plot_compare(self, *, cur_plot, compare_path, is_spark=False):
        prevPlt = SqlPerfPlot(path=compare_path, is_spark=is_spark)
        assert(cur_plot.qNames == prevPlt.qNames)
        assert(cur_plot.numUsers == prevPlt.numUsers)
        assert(cur_plot.notes == prevPlt.notes)
        assert(cur_plot.ds == prevPlt.ds)

        delta = 100.0 * (1 - np.array(cur_plot.qAvg) / np.array(prevPlt.qAvg))
        fig = plt.figure(figsize=(8.5, 5))
        plt.bar(range(len(delta)), delta)
    
        plt.xticks(np.arange(len(cur_plot.qNames)), cur_plot.qNames, rotation=-90)
        if is_spark:
            prevVer = 'Spark'
        else:
            prevVer = prevPlt.verStr

        plt.title("Perf Comparison ({} vs {}) Ave: {:.1f}%\n{} Users, {} Nodes of {}, {}"
                  .format(prevVer, cur_plot.verStr, delta.mean(), cur_plot.numUsers, cur_plot.notes[0], cur_plot.notes[1], cur_plot.ds))
        plt.xlabel('Query')
        plt.ylabel('% Execution Time Decrease')

        return fig

    def _create_pdf(self, *, b1_path, b2_path=None, is_spark=False, out_path):
        b1_plot = SqlPerfPlot(path=b1_path)
        figList = []
        figList.append(b1_plot.plotAvg(b2_path=b2_path, is_spark=is_spark))
        if b2_path:
            figList.append(self._plot_compare(cur_plot=b1_plot, compare_path=b2_path, is_spark=is_spark))
        figList.append(b1_plot.plotIntervals(padding=0.2))
        if b2_path:
            prevPlt = SqlPerfPlot(path=b2_path, is_spark=is_spark)
            figList.append(prevPlt.plotIntervals(padding=0.2))

        with PdfPages(out_path) as pdf:
            for fig in figList:
                pdf.savefig(fig)

        """
        if args.interactive:
            plt.show()
        """

    def _path_for_build(self, *, test_group, bnum, iteration=0):
        filename_pat_1 = "-{}-xcalar_{}.json".format(iteration, test_group)
        filename_pat_2 = "-{}_{}.json".format(iteration, test_group)
        build_root = os.path.join(self.input_root, str(bnum))
        for name in os.listdir(build_root):
            if filename_pat_1 in name or filename_pat_2 in name:
                return os.path.join(build_root, name)
        return None


    def compare(self, *, test_group, bnum1, bnum2, is_spark=False):
        """
        Return the path to the .pdf file comparing the given builds.
        """
        key = self._cache_key(test_group=test_group, bnum1=bnum1, bnum2=bnum2)
        if key in self.path_cache:
            # If already exists, just return path.
            self.logger.info("returning cached {}".format(key))
            return self.path_cache[key]

        # Generate the output path.
        out_path = os.path.join(self.pdf_pat.format(test_group, str(bnum1), str(bnum2)))
        os.makedirs(os.path.dirname(out_path), exist_ok=True)

        # If the file exists, cache the path and return it.
        if os.path.isfile(out_path):
            self.logger.info("returning found {}".format(out_path))
            self.path_cache[key] = out_path
            return out_path

        self.logger.info("creating {}".format(out_path))

        # Find appropriate input files for the given builds
        b1_path = self._path_for_build(test_group=test_group, bnum=bnum1)
        if not b1_path:
            raise ValueError("no appropriate input data file for {} {}"
                             .format(test_group, bnum1))

        b2_path = self._path_for_build(test_group=test_group, bnum=bnum2)
        if not b2_path:
            raise ValueError("no appropriate input data file for {} {}"
                             .format(test_group, bnum2))


        self._create_pdf(b1_path=b1_path, b2_path=b2_path, out_path=out_path)
        self.path_cache[key] = out_path
        return out_path

# In-line "unit test"
if __name__ == '__main__':
    print("Compile check A-OK!")
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(threadName)s - %(funcName)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    logger = logging.getLogger(__name__)
    sql_pdf = SqlPerfComparisonPdf()
    print(sql_pdf.compare(test_group='tpchTest', bnum1=496, bnum2=508))
