#!/bin/bash

set -x

# Extra package needed
/opt/xcalar/bin/pip install -U sql_magic

# 2. Fix allow_remote to jupyter
JUPYTER_CONF=/var/opt/xcalar/.jupyter/jupyter_notebook_config.py
sed -i '/c.NotebookApp.allow_remote_access/d' $JUPYTER_CONF
echo "c.NotebookApp.allow_remote_access = True" >> $JUPYTER_CONF

# 3. Fix local admin login
CONF=/var/opt/xcalar/config
mkdir -p $CONF
cat > $CONF/defaultAdmin.json <<'EOF'
{
  "username": "xdpadmin",
  "password": "9021834842451507407c09c7167b1b8b1c76f0608429816478beaf8be17a292b",
  "email": "info@xcalar.com",
  "defaultAdminEnabled": true
}
EOF
chmod 0700 $CONF
chmod 0600 $CONF/defaultAdmin.json
chown -R xcalar:xcalar $CONF

if test -e /tmp/genDefaultAdmin.sh; then
    mv /tmp/genDefaultAdmin.sh /opt/xcalar/scripts/
fi

exit 0
