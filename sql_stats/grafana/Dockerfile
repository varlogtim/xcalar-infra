FROM tiangolo/uwsgi-nginx-flask:python3.6

MAINTAINER Robert Stephens <rstephens@xcalar.com>

# Environment configuration override as needed...
ENV LOG_LEVEL=INFO

# Context is set to xcalar-infra/ by dbuild
COPY sql_stats/grafana/requirements.txt /app
RUN pip install --no-cache-dir -r requirements.txt

# Flask app needs to be in main.py for NGINX container
COPY sql_stats/grafana/sql_stats_datasource.py /app/main.py

RUN mkdir -p /app/sql_stats
COPY sql_stats /app/sql_stats/

RUN mkdir -p /app/py_common
COPY py_common /app/py_common/
