#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import datetime
import gzip
import json
import logging
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
import os
import time

from extract import JSONExtract
from findfiles import XcalarStatsFileFinder

class FigureCfg(object):
    """
    Wrapper for a single-figure configuration:

        {
            figsize: (width,height),
            title: <str>,
            xlabel: <str>,
            y1label: <str>,
            y1color: <str>,
            y2label: <str>,
            y2color: <str>,
            y1range: (min, max),
            y2range: (min, max),

            metrics: [
                {xy_expr: <expr>},

                {key_expr: <expr>,
                 val_expr: <expr>,
                 swapxy: <bool>,
                 y2:<bool>},
            ]
        }
    """
    def __init__(self, *, parent, dikt):
        self.parent = parent
        self.dikt = dikt
        metrics = dikt.get('metrics', None)
        if not metrics:
            raise ValueError("missing or empty \"metrics\"")

    def get(self, key, default=None):
        """
        Get the value of a configuration parameter
        Fall back to parent configuration if not present
        in "our" configuration.
        """
        val = self.dikt.get(key, None)
        if val is None:
            val = self.parent.get(key, None)
        if val is None:
            return default
        return val


class FigureGroupCfg(object):
    """
    configureation for a page of matplotlib figures
    """
    def __init__(self, *, dikt):
        self.dikt = dikt

    def figures(self):
        return [FigureCfg(parent=self, dikt=d) for d in self.dikt.get('figures', [])]

    def get(self, key, default=None):
        """
        Get the value of a configuration parameter
        """
        return self.dikt.get(key, default)


def get_ts(*, dt, tm, tz):

    (year, month, day) = dt.split("-")
    (hour, minute, second) = tm.split(":")

    dt = tz.localize(datetime.datetime(int(year), int(month), int(day),
                                       int(hour), int(minute), int(second)))
    return dt.timestamp()


def load_json(path):
    try:
        with open(path) as fp:
            return json.load(fp)
    except:
        with gzip.open(path) as fp:
            return json.load(fp)


def plot(*, fig_group, dsh, plotdir, start_ts, end_ts, tz, nodes=None):
    """
    Takes a list of FigureCfg
    """

    logger = logging.getLogger(__name__)

    paths_by_node = XcalarStatsFileFinder(dsh=dsh).\
                        system_stats_files(start_ts=start_ts,
                                           end_ts=end_ts,
                                           nodes=nodes)

    now_x10 = time.time()*10

    for node in sorted(list(paths_by_node.keys())):
        will_plot = False
        points_per_fig = {}
        for path in paths_by_node.get(node):
            logger.info("processing: {}".format(path))
            je = JSONExtract(dikt=load_json(path))

            figures = fig_group.figures()
            for fidx,fcfg in enumerate(figures):

                # All sets of points to plot for a specific figure
                fig_points = points_per_fig.setdefault(fidx, {})

                for midx,mcfg in enumerate(fcfg.get('metrics')):

                    # The points to plot for a specific metric
                    points = fig_points.setdefault(midx, [])

                    if 'xy_expr' in mcfg:
                        points.extend(je.extract_xy(xy_expr=mcfg.get('xy_expr')))

                    elif 'key_expr' in mcfg and 'val_expr' in mcfg:
                        points.extend(je.extract_kv(key_expr=mcfg.get('key_expr'),
                                                    val_expr=mcfg.get('val_expr')))
                if len(points):
                    will_plot = True

        if not will_plot:
            continue

        os.makedirs(plotdir, exist_ok=True)
        outpath = os.path.join(plotdir, "node{}.pdf".format(node))

        with PdfPages(outpath) as pdf:
            logger.info("plotting: {}".format(outpath))
            for fidx,fcfg in enumerate(figures):
                fig,ax1 = plt.subplots(figsize=fcfg.get('figsize', (8.5, 5)))
                ax1.set_xlabel(fcfg.get('xlabel', 'time (s)'))
                ax1.set_title(fcfg.get('title', ''))
                ax2 = None


                y1color = fcfg.get('y1color', 'black')
                ax1.set_ylabel(fcfg.get('y1label', ''), color=y1color)
                y1range = fcfg.get('y1range', None)
                if y1range:
                    ax1.axis(ymin=y1range[0], ymax=y1range[1])
                ax1.tick_params(axis='y', labelcolor=y1color)

                y2label = fcfg.get('y2label', None)
                if y2label is not None:
                    ax2 = ax1.twinx()  # instantiate a second axes that shares the same x-axis
                    y2color = fcfg.get('y2color', 'red')
                    ax2.set_ylabel(y2label, color=y2color)
                    y2range = fcfg.get('y2range', None)
                    if y2range:
                        ax2.axis(ymin=y2range[0], ymax=y2range[1])
                    ax2.tick_params(axis='y', labelcolor=y2color)

                fig_points = points_per_fig.get(fidx)
                for midx,mcfg in enumerate(fcfg.get('metrics')):
                    points = fig_points.get(midx, None)
                    if not points:
                        continue
                    if mcfg.get('swapxy', False):
                        points = [(y,x) for (x,y) in points]

                    # ASS-U-ME: the x-axis is timestamps
                    plot_points = []
                    for pt in points:
                        # Best effort rescale timestamp to seconds
                        # if (presumably) in ms or us
                        ts = pt[0]
                        if ts > now_x10:
                            ts = ts/1000
                        if ts > now_x10:
                            ts = ts/1000

                        # Exclude points outside our time range
                        if ts < start_ts or ts > end_ts:
                            continue

                        plot_points.append((ts, pt[1]))

                    plot_points.sort()

                    xes = [datetime.datetime.fromtimestamp(pt[0], tz=tz) for pt in plot_points]
                    yes = [pt[1] for pt in plot_points]

                    label = mcfg.get('label', 'Metric')
                    if mcfg.get('ploty2', False):
                        color = mcfg.get('color', y2color)
                        ax2.plot(xes, yes, color=color, label=label)
                    else:
                        color = mcfg.get('color', y1color)
                        ax1.plot(xes, yes, color=color, label=label)

                fig.autofmt_xdate()
                fig.legend(loc="lower left")
                if y2label is not None:
                    fig.tight_layout()  # otherwise the right y-label is slightly clipped
                pdf.savefig(fig)


if __name__ == "__main__":
    import argparse
    import pytz
    import sys

    # It's log, it's log... :)
    logging.basicConfig(level=logging.INFO,
                        format="'%(asctime)s - %(levelname)s - %(threadName)s - %(funcName)s - %(message)s",
                        handlers=[logging.StreamHandler(sys.stdout)])

    argParser = argparse.ArgumentParser()
    argParser.add_argument('--dsh', required=True, type=str,
                                help='path to DataflowStatsHistory directory')
    argParser.add_argument('--plotdir', default="./plots", type=str,
                                help='path to plots directory')
    argParser.add_argument('--cfg', default="./cfg/cpu_simple.json", type=str,
                                help='path to figure group configuration file')

    argParser.add_argument('--start_ts', default=None, type=int,
                                help='start timestamp (s)')
    argParser.add_argument('--end_ts', default=None, type=int,
                                help='end timestamp (s)')

    argParser.add_argument('--start_date', default=None, type=str,
                                help='start date (YYYY-MM-DD)')
    argParser.add_argument('--start_time', default=None, type=str,
                                help='start time (HH:MM:SS)')
    argParser.add_argument('--end_date', default=None, type=str,
                                help='end date (YYYY-MM-DD)')
    argParser.add_argument('--end_time', default=None, type=str,
                                help='end time (HH:MM:SS)')
    argParser.add_argument('--tz', default="America/Los_Angeles", type=str,
                                help='timezone for input/display')

    argParser.add_argument('--node', default=None, type=str, action="append",
                                help='plot data only for the given node(s)')

    args = argParser.parse_args()

    if not os.path.exists(args.dsh):
        raise ValueError("dsh path {} does not exist".format(args.dsh))

    tz = pytz.timezone(args.tz)
    now = datetime.datetime.now(tz=tz)
    today = "{}-{}-{}".format(now.year, now.month, now.day)

    start_ts = args.start_ts
    if not start_ts:
        start_dt = args.start_date
        if not start_dt:
            start_dt = today
        tm = args.start_time
        if not tm:
            tm = "00:00:00"
        start_ts = get_ts(dt=start_dt, tm=tm, tz=tz)

    end_ts = args.end_ts
    if not end_ts:
        end_dt = args.end_date
        if not end_dt:
            # Same as start date then
            end_dt = start_dt
        tm = args.end_time
        if not tm:
            tm = "23:59:59"
        dt_str = "{} {}".format(end_dt, tm)
        end_ts = get_ts(dt=end_dt, tm=tm, tz=tz)

    with open(args.cfg) as fp:
        fig_group = FigureGroupCfg(dikt=json.load(fp))

    plot(fig_group=fig_group, dsh=args.dsh, plotdir=args.plotdir,
         start_ts=start_ts, end_ts=end_ts, tz=tz, nodes=args.node)
