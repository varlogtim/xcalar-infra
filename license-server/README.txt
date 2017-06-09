This directory contains a backup of the meaningful parts of the simple 
https service on zd1.xcalar.com that serves license keys up to ZenDesk.

The code, as it is currently written, assumes a few things:

1. It is hosted by the user xcalar in the directory /home/xcalar/todo-api.

2. License keys are stored in a sqlite file called license_keys.sqlite.

3. There is a Python2.7 virtenv called flask located in /home/xcalar/todo-api.

4. The service has a caddy web server started as a proxy for it.  The 
caddy/Caddyfile is the configuration.  Caddy is started with the command:
/usr/bin/caddy -agree -root /var/www -conf /etc/caddy/Caddyfile

5. The flask part of the service is started in the /home/xcalar/todo-api 
directory with the command:
./app.py 

6. Two other files are required for the flask service to function:
  * a license key reader called readKey from $XLRDIR/src/bin/licenseTools
  * the Xcalar license public key called EcdsaPub.key from $XLDIR/src/data


