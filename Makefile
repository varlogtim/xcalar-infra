SHELL=/bin/bash

all: .venv/bin/activate

.venv/bin/activate: .venv frozen.txt
	.venv/bin/pip install -r frozen.txt
	touch $@

.venv:
	virtualenv $@


