.PHONY: run

XC_LICENSE_SERVER_SETTINGS ?= config.py
FLASK_APP ?= app.py
FLASK_DEBUG ?= 1 # Debug by default

export XC_LICENSE_SERVER_SETTINGS
export FLASK_APP
export FLASK_DEBUG

all: run

venv: venv/bin/activate
venv/bin/activate: requirements.txt
	test -d venv || virtualenv venv
	venv/bin/pip install -Ur requirements.txt
	touch venv/bin/activate

run: venv
	venv/bin/python2.7 -m flask initdb
	venv/bin/python2.7 -m flask run

test: venv
	venv/bin/python2.7 -m flask initdb
	export FLASK_DEBUG=1
	venv/bin/python2.7 -m flask run --host 0.0.0.0

clean:
	rm -rf venv
