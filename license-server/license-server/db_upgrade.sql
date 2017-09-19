/*
This file should be append only; this represents upgrading the SQL DB from
the beginning of time until present day.
*/

PRAGMA foreign_keys=ON;

---------------------------------- VERSION  0 ----------------------------------

CREATE TABLE IF NOT EXISTS licenses (
    Owner       TEXT                NOT NULL,
    Key         TEXT                NOT NULL
);

---------------------------------- VERSION  1 ----------------------------------

CREATE TABLE IF NOT EXISTS organization (
    org_id      INTEGER PRIMARY KEY,
    name        TEXT                UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS owner (
    owner_id    INTEGER PRIMARY KEY,
    name        TEXT                NOT NULL,
    org_id      INTEGER             NOT NULL,
    FOREIGN KEY(org_id) REFERENCES organization(org_id)
);

-- rename table to be singular table name; lowercase column names
CREATE TABLE IF NOT EXISTS license (
    key         TEXT                UNIQUE NOT NULL,
    org_id      INTEGER             NOT NULL,
    active      BOOLEAN             NOT NULL DEFAULT 1,
    FOREIGN KEY(org_id) REFERENCES organization(org_id)
);

CREATE TABLE IF NOT EXISTS activation (
    act_id      INTEGER PRIMARY KEY,
    key         TEXT                NOT NULL,
    active      BOOLEAN             NOT NULL,
    timestamp   DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(key) REFERENCES license(key)
);

-- Migrate data from previous version
INSERT INTO organization (name)
SELECT DISTINCT *
FROM
    (SELECT Group_Concat(Owner)
     FROM
         (SELECT DISTINCT Owner, Key
          FROM licenses)
     GROUP BY Key);

PRAGMA case_sensitive_like=ON;
INSERT INTO owner (name, org_id)
SELECT Owner, org_id
FROM
    (SELECT DISTINCT Owner
     FROM licenses) owners
INNER JOIN organization ON organization.name LIKE '%'||owners.Owner||'%';
PRAGMA case_sensitive_like=OFF;

INSERT INTO license (key, org_id)
SELECT DISTINCT orgLicenses.Key, organization.org_id
FROM
    (SELECT Key, Group_Concat(Owner) as name
     FROM
         (SELECT DISTINCT Owner, Key
          FROM licenses)
     GROUP BY Key) orgLicenses
LEFT JOIN organization ON orgLicenses.name = organization.name;

DROP TABLE licenses;

---------------------------------- VERSION  2 ----------------------------------

CREATE TABLE IF NOT EXISTS marketplace (
    marketplace_id  INTEGER PRIMARY KEY,
    key             TEXT                NOT NULL,
    url             TEXT                NOT NULL,
    marketplaceName TEXT                NOT NULL,
    timestamp       DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(key) REFERENCES license(key)
);

