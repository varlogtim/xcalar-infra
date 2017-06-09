#!/usr/bin/python

from collections import defaultdict
import json
import os
import argparse
import sqlite3

dir_path = os.path.dirname(os.path.realpath(__file__))
license_key_db_name = dir_path + '/license_keys.sqlite'

def open_db():
    conn = sqlite3.connect(license_key_db_name)
    return [conn, conn.cursor()]

def close_db(conn):
    conn.close()

def fetch_everything(c):
    c.execute('select * from licenses')
    return c.fetchall()

def fetch_names(c):
    c.execute('select distinct Owner from licenses')
    names = c.fetchall()
    names = [item for sublist in names for item in sublist]
    return names

def fetch_licenses_for_name(c, name):
    c.execute('select Key from licenses where Owner="{owner}"'.\
              format(owner=name))
    keys = c.fetchall()
    keys = [item for sublist in keys for item in sublist]
    return keys

def list_names(name):
    my_keys = defaultdict(list)
    if (name is None):
        [conn, c] = open_db()
        table = fetch_everything(c)
        close_db(conn)
        for row in table:
            my_keys[row[0]].append(row[1])
    else:
        [conn, c] = open_db()
        names = fetch_names(c)
        if not name in names:
            close_db(conn)
            print "Name not found!"
            exit(1)
        table = fetch_licenses_for_name(c, name)
        close_db(conn)
        for row in table:
            my_keys[name].append(row)
    print json.dumps(my_keys, indent=4, sort_keys=True)

def insert(name, key):
    [conn, c] = open_db()
    c.execute('insert into licenses (Owner, Key) values ("{owner}", "{key}")'.\
              format(owner=name, key=key))
    conn.commit()
    close_db(conn)

def delete(name, key):
    [conn, c] = open_db()
    if (key is None): 
        c.execute('delete from licenses where Owner="{owner}"'.\
              format(owner=name))
    elif ("%" in key):
        c.execute('delete from licenses where Owner="{owner}" and Key like "{key}"'.\
                  format(owner=name, key=key))
    else:
        c.execute('delete from licenses where Owner="{owner}" and Key="{key}"'.\
                  format(owner=name, key=key))
    conn.commit()
    close_db(conn)


parser = argparse.ArgumentParser()
parser.add_argument("--name", "-n", help="owner of the key")
parser.add_argument("--key", "-k", help="the key to be inserted")
parser.add_argument("--command", "-c", required=True, 
                    choices=['insert', 'delete', 'list'], 
                    help="action to be performed: insert or delete")
args = parser.parse_args()

if (args.command == 'delete' and
    args.name is None):
    parser.print_help()
    print "Name is required in order to delete\n"
    exit(1)

if (args.command == 'insert' and
    (args.name is None or args.key is None)):
    parser.print_help()
    print "Name and key are required in order to insert\n"
    exit(1)

if (args.command == 'list'):
    list_names(args.name)

if (args.command == 'insert'):
    insert(args.name, args.key)

if (args.command == 'delete'):
    delete(args.name, args.key)
