#!/usr/bin/env python3

# Copyright 2020 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

import jsonpath_rw_ext as jsonpath

"""
An "xy_expr" expression returns alternating x and y values when iterating over matches...

    json_data = {"foo":[{"xval":<x1>, "yval":<y1>},{"xval":<x2>, "yval":<y2>}]} 
    xy_expr = "$.foo.[xval,yval]"

An "key_expr/val_expr" expression pair uses the key expression to find a dictionary for which the
key values are one half of ... and the val_expr is used to find the paired values by matching
the structures "keyed" by each of the key values.

    json_data = {"foo": {<x1>:{"yval": <y1>, "bar": "something"},
                         <x2>:{"yval": <y2>, "bar": "something else"}}}
    key_expr = "$.foo"
    val_expr = "$.yval"

Both would result in:
        [(<x1>, <y1>), (<x2>, <y2>)]
"""
class JSONExtract(object):

    def __init__(self, *, dikt):
        self.dikt = dikt

    def _convertvals(self, vals):
        it = iter(vals)
        return list(zip(it, it))

    def extract_xy(self, *, xy_expr):
        vals = []
        for match in jsonpath.parse(xy_expr).find(self.dikt):
            vals.append(match.value)
        return self._convertvals(vals)

    def extract_kv(self, *, key_expr, val_expr, ):
        vals = []
        for m1 in jsonpath.parse(key_expr).find(self.dikt):
            d1 = m1.value
            for key,child in d1.items():
                for m2 in jsonpath.parse(val_expr).find(child):
                    vals.append(key)
                    vals.append(m2.value)
        return self._convertvals(vals)

if __name__ == "__main__":
    test_data={
        'foo': {'1234':{'sys': 4, 'idle': 96},
                '1235':{'sys': 5, 'idle': 95}},
        'bar': {'bongo': {'1234':{'sys': 40, 'idle': 60},
                          '1235':[{'sys': 50, 'idle': 50},
                                  {'sys': 51, 'idle': 49}]}},
        'blah': [{'x': 1, 'y': 10},
                 {'x': 2, 'y': 20},
                 {'x': 3, 'y': 30}]
        }

    je = JSONExtract(dikt=test_data)
    print("expect [(1, 10), (2, 20), (3, 10)]")
    print("got: {}".format(je.extract_xy(xy_expr="$.blah[*][x,y]")))

    print("expect [(1234, 4), (1235, 5)]")
    print("got: {}".format(je.extract_kv(key_expr="$.foo", val_expr="$..sys")))

    print("expect [(1234, 60), (1235, 50), (1235, 49)]")
    print("got: {}".format(je.extract_kv(key_expr="$.bar.bongo", val_expr="$..idle")))

    print("expect: {'x': 2, 'y': 20}")
    for m in jsonpath.parse("$.blah[?(x=2)]").find(test_data):
        print("got: {}".format(m.value))
