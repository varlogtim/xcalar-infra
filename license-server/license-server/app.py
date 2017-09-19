from datetime import datetime, timedelta
from collections import defaultdict
import subprocess
import ast
import re
import sqlite3
import os
import sys
import json

from flask import Flask, jsonify, abort, render_template, g, request, make_response, current_app
from functools import update_wrapper
import licenseServerApi

# Copied from http://flask.pocoo.org/snippets/56
# This creates a decoration @crossdomain that allows
# that endpoint to be called from another domain via AJAX
def crossdomain(origin=None, methods=None, headers=None,
                max_age=21600, attach_to_all=True,
                automatic_options=True):
    if methods is not None:
        methods = ', '.join(sorted(x.upper() for x in methods))

    if headers is not None and not isinstance(headers, basestring):
        headers = ', '.join(x.upper() for x in headers)

    if not isinstance(origin, basestring):
        origin = ', '.join(origin)

    if isinstance(max_age, timedelta):
        max_age = max_age.total_seconds()

    def get_methods():
        if methods is not None:
            return methods
        options_resp = current_app.make_default_options_response()
        return options_resp.headers['allow']

    def decorator(f):
        def wrapped_function(*args, **kwargs):
            if automatic_options and request.method == 'OPTIONS':
                resp = current_app.make_default_options_response()
            else:
                resp = make_response(f(*args, **kwargs))

            if not attach_to_all and request.method != 'OPTIONS':
                return resp

            h = resp.headers
            h['Access-Control-Allow-Origin'] = origin
            h['Access-Control-Allow-Methods'] = get_methods()
            h['Access-Control-Max-Age'] = str(max_age)

            if headers is not None:
                h['Access-Control-Allow-Headers'] = headers

            return resp

        f.provide_automatic_options = False
        f.required_methods = ['OPTIONS']
        return update_wrapper(wrapped_function, f)

    return decorator

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
def getKeyInfo(key):
    p = subprocess.Popen([readKeyCmd, "-k", pubKey, "-l", key], stdout=subprocess.PIPE)
    cmdOutput = p.communicate()[0]
    if p.returncode != 0:
        raise Exception("%s returned %d" % (readKeyCmd, p.returncode))

    keyProps = {}
    for line in cmdOutput.splitlines():
        elements = json.loads("{%s}" % line)
        keyProps.update(elements)

    return keyProps

def getKeys(name = None, organization = None):
    with getDb() as conn:
        keys = []
        cursor = conn.cursor()
        keys = licenseServerApi.listKeys(cursor, name, organization)

    if not keys:
        return []

    return [getKeyInfo(k[2]) for k in keys]

# Request handlers
@app.errorhandler(404)
def pageNotFound(error):
    return render_template('_error_license.html'), 404

@app.route('/')
def index():
    return "Hello, World!"

# XXX Use JWT or some other way to secure these HTTP endpoints (beginning with secure/)
@app.route('/license/api/v1.0/secure/listactivation', methods=['POST'])
def listActivation():
    try:
        return listTable("activation", request.get_json())
    except:
        abort(404)

@app.route('/license/api/v1.0/secure/listowner', methods=['POST'])
def listOwner():
    try:
        return listTable("owner", request.get_json())
    except:
        abort(404)

@app.route('/license/api/v1.0/secure/listlicense', methods=['POST'])
def listLicense():
    try:
        return listTable("license", request.get_json())
    except:
        abort(404)

@app.route('/license/api/v1.0/secure/listorganization', methods=['POST'])
def listOrganization():
    try:
        return listTable("organization", request.get_json())
    except:
        abort(404)

@app.route('/license/api/v1.0/secure/listmarketplace', methods=['POST'])
def listMarketplace():
    try:
        return listTable("marketplace", request.get_json())
    except:
        abort(404)

@app.route('/license/api/v1.0/secure/addlicense', methods=['POST'])
@crossdomain(origin="*", headers="Content-Type, Origin")
def insertLicense():
    jsonInput = request.get_json();
    if "secret" not in jsonInput or jsonInput["secret"] != "xcalarS3cret":
        abort(404)

    name = jsonInput.get("name", None)

    try:
        organization = jsonInput["organization"]
        key = jsonInput["key"]
    except:
        abort(404)

    try:
        with getDb() as conn:
            cursor = conn.cursor()
            licenseServerApi.insert(cursor, name, organization, key)
    except:
        abort(404)

    return jsonify({"success": True})

def listTable(tableName, jsonInput):
    if "secret" not in jsonInput or jsonInput["secret"] != "xcalarS3cret":
        raise Exception("Invalid secret provided")

    if not tableName.isalnum():
        raise Exception("tableName must contain only alpha-numeric characters")

    with getDb() as conn:
        cursor = conn.cursor()
        return jsonify(licenseServerApi.listTable(cursor, tableName))


@app.route('/license/api/v1.0/keys/<string:ownerName>', methods=['GET'])
@crossdomain(origin="*")
def getKeysByOwner(ownerName):
    keys = getKeys(name=ownerName)
    if not keys:
        return jsonify({})

    return jsonify({'key': keys})

@app.route('/license/api/v1.0/keysbyorg/<string:organizationName>', methods=['GET'])
@crossdomain(origin="*")
def getKeysByOrg(organizationName):
    keys = getKeys(organization=organizationName)
    if not keys:
        return jsonify({})

    return jsonify({'key': keys})

@app.route('/license/api/v1.0/checkvalid', methods=['POST'])
def checkvalid():
    jsonInput = request.get_json()
    if "key" not in jsonInput:
        abort(400)
    key = jsonInput["key"]

    with getDb() as conn:
        retObj = {"success": False}

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
        else:
            activeRowId = cursor.lastrowid

            cursor.execute("""
                SELECT active
                FROM activation
                WHERE rowid = :rowid""",
                {"rowid": activeRowId})
            dbActive = cursor.fetchone()
            if dbActive[0]:
                try:
                    retObj["keyInfo"] = getKeyInfo(key)
                    retObj["success"] = True
                except Exception as e:
                    retObj["error"] = "Error parsing license key: %s" % e
            else:
                retObj["error"] = "License key inactive"

    return jsonify(retObj)

@app.route('/license/api/v1.0/marketplacedeploy', methods=['POST'])
def marketplaceDeploy():
    jsonInput = request.get_json()
    try:
        marketplaceName = jsonInput["marketplaceName"]
        url = jsonInput["url"]
        key = jsonInput["key"]
    except:
        abort(400)

    with getDb() as conn:
        retObj = {"success": False}

        cursor = conn.cursor()
        cursor.execute("SELECT key FROM license WHERE key = :licenseKey", { "licenseKey": key })
        if not cursor.rowcount:
            retObj["error"] = "License key not found"
            return jsonify(retObj)

        cursor.execute("INSERT INTO marketplace (key, url, marketplaceName) VALUES(:licenseKey, :url, :marketplaceName)", {"licenseKey": key, "url": url, "marketplaceName": marketplaceName })
        retObj["success"] = True

    return jsonify(retObj)

@app.route('/license/api/v1.0/getdeployment/<string:organizationName>', methods=['GET'])
@crossdomain(origin="*")
def getDeployments(organizationName):
    with getDb() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT url, marketplaceName, timestamp, license.key FROM marketplace INNER JOIN license ON marketplace.key = license.key INNER JOIN organization ON license.org_id = organization.org_id WHERE organization.name = :orgName ORDER BY marketplace.timestamp DESC", { "orgName": organizationName })
        headers = [ "url", "marketplaceName", "timestamp", "licenseKey" ]
        retVals = []
        for row in cursor.fetchall():
            dictionary = { name: value for (name, value) in zip(headers, row) }
            dictionary["keyInfo"] = getKeyInfo(dictionary["licenseKey"])
            del dictionary["licenseKey"]
            retVals.append(dictionary)
        return jsonify(retVals)



@app.route('/license/api/v1.0/activations/<string:key>', methods=['GET'])
def activations(key):
    with getDb() as conn:
        actives = []
        cursor = conn.cursor()
        cursor.execute("""
            SELECT (timestamp, key)
            FROM activation
            """)
        actives = cursor.fetchall()
        return jsonify({"activations": actives})

@app.route('/license/api/v1.0/keyshtml/<string:ownerName>', methods=['GET'])
def getHtmlKeysByOwner(ownerName):
    keys = getKeys(name=ownerName)
    if not keys:
        abort(404)

    output = sorted(keys, key=lambda k: datetime.strptime(k['expiration'], '%m/%d/%Y'), reverse=True)
    return render_template('_table_render.html', keys=output)

@app.route('/license/api/v1.0/keysbyorghtml/<string:organizationName>', methods=['GET'])
def getHtmlKeysByOrg(organizationName):
    keys = getKeys(organization=organizationName)
    if not keys:
        abort(404)

    output = sorted(keys, key=lambda k: datetime.strptime(k['expiration'], '%m/%d/%Y'), reverse=True)
    return render_template('_table_render.html', keys=output)

if __name__ == '__main__':
    app.run(debug=False,host='0.0.0.0')
