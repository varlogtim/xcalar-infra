#!/usr/bin/python

# Copyright 2018 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import argparse
from collections import Counter
import csv
import subprocess as sp
import re
import sys

argParser = argparse.ArgumentParser()

argParser.add_argument('-b', dest='binary', required=False,
                    help='Path to binary run under guard rails')
argParser.add_argument('-c', dest='sortct', required=False, action='store_true',
                    help='Sort by leak count instead total memory leaked')
argParser.add_argument('-f', dest='fin', required=True,
                    help='GuardRails leak dump CSV file')
argParser.add_argument('-t', dest='top', required=False, type=int, default=sys.maxsize,
                    help='Only show up to this many top contexts')
args = argParser.parse_args()


class grDump(object):
    def __init__(self):
        self.data = []
        self.leaks = []

    def loadData(self):
        with open(args.fin) as fh:
            self.data = fh.read().splitlines()

    def resolveSym(self, addr):
        addrProc = sp.Popen("addr2line -Cfse " + args.binary + " " + str(addr), shell=True, stdout=sp.PIPE)
        return filter(lambda x: x, addrProc.stdout.read().split('\n'))

    def resolveSyms(self, addrs):
        # addr2line is surprisingly slow; resolves about 6 backtraces/sec
        addrProc = sp.Popen("addr2line -Capfse " + args.binary + " " + str(addrs), shell=True, stdout=sp.PIPE)
        return addrProc.stdout.read()

    def parseLeaks(self):
        ctr = Counter(self.data)
        leakFreq = ctr.items()
        leakFreq.sort(key=lambda x: x[1], reverse=True)
        leakFreq = [str(x[1]) + "," + x[0] for x in leakFreq]

        for row in csv.reader(leakFreq, delimiter=','):
            leak = filter(lambda x: x, row)
            count = int(leak[0])
            elmBytes = int(leak[1])
            totBytes = count * elmBytes
            self.leaks.append({'count': count, 'elmBytes': elmBytes, 'totBytes': totBytes, 'backtrace': leak[2:]})


    def printLeaks(self):
        self.parseLeaks()

        totalBytesLeaked = 0
        totalLeakCount = 0

        numContexts = len(self.leaks)
        for leak in self.leaks:
            totalBytesLeaked += leak['totBytes']
            totalLeakCount += leak['count']

        print "Leaked total of {:,d} bytes across {:,d} leaks from {:,d} contexts"\
                .format(totalBytesLeaked, totalLeakCount, numContexts)
        if args.sortct:
            self.leaks.sort(key=lambda x: x['count'], reverse=True)
        else:
            self.leaks.sort(key=lambda x: x['totBytes'], reverse=True)

        context = 0
        for leak in self.leaks:
            print "================================ Context {:>6,d} / {:,d} ================================"\
                    .format(context, numContexts)
            print "Leaked {:,d} bytes across {:,d} allocations of {:,d} bytes each:"\
                    .format(leak['totBytes'], leak['count'], leak['elmBytes'])
            leakNum = 0

            if args.binary:
                syms = self.resolveSyms(' '.join(leak['backtrace']))
                for sym in syms.split('\n'):
                    if not sym:
                        continue
                    shortSym = re.sub(r'\(.*\)', r'', sym)
                    print "#{: <2} {}".format(leakNum, shortSym)
                    leakNum += 1
            else:
                for addr in leak['backtrace']:
                    print "#{: <2} {} (No symbols, see -b option)".format(leakNum, addr)
                    leakNum += 1

            context += 1
            if context >= args.top:
                break

dumper = grDump()

dumper.loadData()
dumper.printLeaks()
