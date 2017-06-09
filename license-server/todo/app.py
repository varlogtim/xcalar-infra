#!flask/bin/python
from flask import Flask, jsonify, abort, render_template
from datetime import datetime
from collections import defaultdict
import subprocess
import ast
import re
import sqlite3
import os
import sys

app = Flask(__name__)

dir_path = os.path.dirname(os.path.realpath(__file__))
license_key_db_name = dir_path + '/license_keys.sqlite'

cmd = "/home/xcalar/todo-api/readKey"

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

@app.errorhandler(404)
def page_not_found(error):
    return render_template('_error_license.html'), 404

@app.route('/')
def index():
    return "Hello, World!"

@app.route('/todo/api/v1.0/keys', methods=['GET'])
def get_all_keys():
    [conn, c] = open_db()
    table = fetch_everything(c)
    close_db(conn)
    my_keys = defaultdict(list)
    for row in table:
        my_keys[row[0]].append(row[1])
    return jsonify({'keys': my_keys})

@app.route('/todo/api/v1.0/keys/<string:name>', methods=['GET'])
def get_key(name):
    [conn, c] = open_db()
    names = fetch_names(c)
    if not name in names:
        close_db(conn)
        abort(404)
    my_keys = fetch_licenses_for_name(c, name)
    close_db(conn)
    output = []
    for key in my_keys:
         cmd_output = subprocess.Popen([cmd, key], stdout=subprocess.PIPE).communicate()[0]
	 fixed_output = re.sub("\n", ',', '{ ' + cmd_output + ' }')
         output.append(ast.literal_eval(fixed_output))
    return jsonify({'key': output })

@app.route('/todo/api/v1.0/keyshtml/<string:name>', methods=['GET'])
def get_htmlkey(name):
    [conn, c] = open_db()
    names = fetch_names(c)
    if not name in names:
        close_db(conn)
        abort(404)
    my_keys = fetch_licenses_for_name(c, name)
    close_db(conn)
    output = []
    cmd = "/home/xcalar/todo-api/readKey"
    for key in my_keys:
         cmd_output = subprocess.Popen([cmd, "-k", "/home/xcalar/todo-api/EcdsaPub.key", "-l", key], stdout=subprocess.PIPE).communicate()[0]
         fixed_output = re.sub("\n", ',', '{ ' + cmd_output + ' }')
         output.append(ast.literal_eval(fixed_output))
    output = sorted(output, key=lambda x: datetime.strptime(x['expiration'], '%m/%d/%Y'), reverse=True)
    return render_template('_table_render.html', keys=output)

if __name__ == '__main__':
    app.run(debug=True,host='0.0.0.0')
