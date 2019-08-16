#!/usr/bin/env python3

# Copyright 2019 Xcalar, Inc. All rights reserved.
#
# No use, or distribution, of this source code is permitted in any form or
# means without a valid, written license agreement with Xcalar, Inc.
# Please refer to the included "COPYING" file for terms and conditions
# regarding the use and redistribution of this software.

class FileGroupsMixin(object):

    @property
    def _file_groups(self):
        if not hasattr(self, '_fgroups'):
            self._fgroups = None
        return self._fgroups

    @_file_groups.setter
    def _file_groups(self, val):
        self._fgroups = val

    def reset_file_groups(self):
        self.meta_coll.replace_one({'_id': 'file_groups'},
                                   {'groups': []},
                                   upsert=True)

    def append_file_group(self, *, group_name, files):
        self.meta_coll.update_one({'_id': 'file_groups'},
                                  {'$push': {'groups': (group_name, files)}},
                                  upsert=True)

    def file_groups(self, *, refresh=False):
        """
            {'_id': 'file_groups',
             'groups': [(<group_name>, [<file_name>, <file_name>, ...]),
                        (<group_name>, [<file_name>, <file_name>, ...])]}
        """
        if not refresh and self._file_groups is not None:
            return self._file_groups
        doc = self.meta_coll.find_one({'_id': 'file_groups'})
        if not doc:
            self._file_groups = []
        else:
            self._file_groups = doc.get('groups', [])
        return self._file_groups

    def file_group_names(self, *, refresh=False):
        return [n for n,l in self.file_groups(refresh=refresh)]

    def expand(self, *, name):
        """
        If given name is a file group, expand to the configured
        list of file names.  Otherwise just return it as the only
        member of the list.
        """
        for gname, files in self.file_groups():
            if name == gname:
                return files
        return [name]

if __name__ == '__main__':
    print("Compile check A-OK!")
