#!/usr/bin/python

import os
from collections import defaultdict
import argparse
import sqlite3
from licenseServerApi import *

dir_path = os.path.dirname(os.path.realpath(__file__))
license_key_db_name = dir_path + '/license_keys.sqlite'

def openDb():
    conn = sqlite3.connect(license_key_db_name)
    return [conn, conn.cursor()]

def closeDb(conn):
    conn.close()

parser = argparse.ArgumentParser()
parser.add_argument("--name", "-n", help="owner of the key")
parser.add_argument("--organization", "-o", help="organization owner belongs to")
parser.add_argument("--key", "-k", help="the key to be inserted")
parser.add_argument("--table", "-t", help="Name of table to display")
parser.add_argument("--command", "-c", required=True,
                    choices=['insert', 'delete', 'list', 'listTable'],
                    help="action to be performed: insert or delete")
args = parser.parse_args()

if (args.command == 'insert' and
    (args.key is None or args.organization is None)):
    parser.print_help()
    print "Organization and key are required in order to insert\n"
    exit(1)

if (args.command == 'listTable' and
    (args.table is None)):
    parser.print_help()
    print "table is required in order to listTable\n"
    exit(1)

if (args.command == 'list'):
    [conn, c] = openDb()
    table = listKeys(c, args.name, args.organization)
    closeDb(conn)

    my_keys = defaultdict(list)
    for row in table:
        my_keys["%s (%s)" % (row[0], row[1])].append(row[2])

    print json.dumps(my_keys, indent=4, sort_keys=True)

if (args.command == 'insert'):
    [conn, c] = openDb()
    insert(c, args.name, args.organization, args.key)
    conn.commit()
    closeDb(conn)

if (args.command == 'delete'):
    [conn, c] = openDb()
    if (args.name is not None):
        deleteName(c, args.name)

    if (args.organization is not None):
        deleteOrganization(c, args.organization)

    if (args.key is not None):
        deleteKey(c, args.key)

    conn.commit()
    closeDb(conn)

if (args.command == 'listTable'):
    [conn, c] = openDb()
    print json.dumps(listTable(c, args.table))
    closeDb(conn)

