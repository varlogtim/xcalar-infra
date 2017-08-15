from datetime import datetime
from collections import defaultdict
import subprocess
import ast
import re
import sqlite3
import os
import sys

from flask import Flask, jsonify, abort, render_template, g

app = Flask(__name__)

app.config.from_object('config')
app.config.from_envvar('XC_LICENSE_SERVER_SETTINGS')

licenseKeyDb = app.config["LICENSE_KEY_DB"]
dbUpgrade = app.config["LICENSE_KEY_DB_UPGRADE"]
pubKey = app.config["XCALAR_PUBLIC_KEY"]

readKeyCmd = "readKey"


# Database management
def getDb():
    """Opens a new database connection if there is none yet for the
    current application context.
    """
    if not hasattr(g, 'sqlite_db'):
        g.sqlite_db = sqlite3.connect(licenseKeyDb)
    return g.sqlite_db

@app.teardown_appcontext
def closeDb(error):
    """Closes the database again at the end of the request."""
    if hasattr(g, 'sqlite_db'):
        g.sqlite_db.close()

def initDb():
    db = getDb()
    with app.open_resource(dbUpgrade, mode='r') as f:
        db.cursor().executescript(f.read())
    db.commit()

@app.cli.command('initdb')
def initDbCommand():
    initDb()
    print 'Database initialized.'

# Helper functions
def getKeysForOrg(organization):
    conn = getDb()

    orgKeys = []
    with conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT (license.key)
            FROM license
            LEFT JOIN organization ON license.org_id = organization.org_id
            WHERE organization.name = :orgname
            """,
            {"orgname": organization})
        orgKeys = cursor.fetchall()

    if not orgKeys:
        return []

    unpackedKeys = []
    for key in [k[0] for k in orgKeys]:
         cmdOutput = subprocess.Popen([readKeyCmd, "-k", pubKey, "-l", key], stdout=subprocess.PIPE).communicate()[0]

         keyProps = {}
         for line in cmdOutput.splitlines():
             elements = line.split(':')
             propName = elements[0].replace('"', '')
             propValue = elements[1].replace('"', '')
             keyProps[propName] = propValue

         unpackedKeys.append(keyProps)

    return unpackedKeys

# Request handlers
@app.errorhandler(404)
def pageNotFound(error):
    return render_template('_error_license.html'), 404

@app.route('/')
def index():
    return "Hello, World!"


@app.route('/license/api/v1.0/keys/<string:organization>', methods=['GET'])
def getKeys(organization):
    keys = getKeysForOrg(organization)
    if not keys:
        abort(404)

    return jsonify({'key': keys})

@app.route('/license/api/v1.0/checkvalid/<string:key>', methods=['POST'])
def checkvalid(key):
    conn = getDb()
    retObj = {"success": False}

    with conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO activation (key, active)
            SELECT :key, active
            FROM license
            WHERE license.key = :key;
            """,
            {"key": key})
        if not cursor.rowcount:
            retObj["error"] = "License key not found"

        activeRowId = cursor.lastrowid

        cursor.execute("""
            SELECT active
            FROM activation
            WHERE rowid = :rowid""",
            {"rowid": activeRowId})
        dbActive = cursor.fetchone()
        if dbActive[0]:
            retObj["success"] = True
        else:
            retObj["error"] = "License key inactive"

    return jsonify(retObj)


@app.route('/license/api/v1.0/activations/<string:key>', methods=['GET'])
def activations(key):
    conn = getDb()
    actives = []
    with conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT (timestamp, key)
            FROM activation
            """)
        actives = cursor.fetchall()
    return jsonify({"activations": actives})

@app.route('/license/api/v1.0/keyshtml/<string:organization>', methods=['GET'])
def getHtmlkey(organization):
    keys = getKeysForOrg(organization)
    if not keys:
        abort(404)

    output = sorted(keys, key=lambda k: datetime.strptime(k['expiration'], '%m/%d/%Y'), reverse=True)
    return render_template('_table_render.html', keys=output)

if __name__ == '__main__':
    app.run(debug=True,host='0.0.0.0')
