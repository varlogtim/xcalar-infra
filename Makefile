SHELL=/bin/bash

all: .venv/bin/activate


.venv/bin/activate: .venv requirements.txt
	.venv/bin/pip install -r requirements.txt

.venv:
	virtualenv $@


