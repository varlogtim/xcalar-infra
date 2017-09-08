import json
import sqlite3

def convertToDict(rowHeaders, row):
    return { name: value for (name, value) in zip(rowHeaders, row) }

def listTable(c, tableName):
    resultSet = c.execute("SELECT * FROM \"%s\"" % tableName)
    rowHeaders = [ tmp[0] for tmp in c.description ]
    return ([convertToDict(rowHeaders, row) for row in resultSet])


def listKeys(c, name, organization):
    return c.execute('SELECT owner.name, organization.name, license.key FROM license INNER JOIN owner ON license.org_id = owner.org_id INNER JOIN organization on owner.org_id = organization.org_id WHERE (:name IS NULL OR owner.name = :name) AND (:organization IS NULL OR organization.name = :organization)', {"name":name, "organization": organization}).fetchall()

def insert(c, name, organization, key):
    if organization is None:
        raise ValueError("organization is required")

    if key is None:
        raise ValueError("key is required")

    # Retrieve organization id or create one if don't exist
    try:
        organizationId = c.execute("SELECT organization.org_id FROM organization WHERE organization.name = :organization", {"organization": organization}).fetchone()[0]
    except Exception as e:
        c.execute("INSERT INTO organization (name) VALUES (:organization)", {"organization": organization})
        organizationId = c.lastrowid

    # Insert person into owner table if don't exist
    if name is not None:
        if (len(c.execute("SELECT name FROM owner WHERE name = :name AND org_id = :orgid", {"name": name, "orgid": organizationId }).fetchall()) == 0):
            c.execute("INSERT INTO owner (name, org_id) VALUES (:name, :orgid)", {"name": name, "orgid": organizationId})

    # Insert key entry
    c.execute("INSERT INTO license (key, org_id) VALUES (:key, :orgid)", {"key": key, "orgid": organizationId})


def deleteName(c, name):
    c.execute("DELETE FROM owner WHERE name=:name", {"name": name})

def deleteKey(c, key):
    c.execute("DELETE FROM license WHERE key=:key", {"key": key})

def deleteOrganization(c, organization):
    c.execute("DELETE FROM organization WHERE name=:organization", {"organization": organization})


