FROM tiangolo/uwsgi-nginx-flask:python3.6

# Context is set to xcalar-infra/ by dbuild

# Flask app needs to be in main.py for NGINX container
COPY coverage/grafana/coverage_datasource.py /app/main.py
COPY coverage/grafana/requirements.txt /app

RUN mkdir -p /app/coverage
COPY coverage/*.py /app/coverage/

RUN mkdir -p /app/py_common
COPY py_common/*.py /app/py_common/

RUN pip install -r requirements.txt

# Environment configuration override as needed...
