FROM tiangolo/uwsgi-nginx-flask:python3.6

# Context is set to xcalar-infra/ by dbuild

# Flask app needs to be in main.py for NGINX container
COPY sql_tpch/grafana/sql_tpch_datasource.py /app/main.py
COPY sql_tpch/grafana/requirements.txt /app
COPY sql_tpch/grafana/uwsgi.ini /app

RUN mkdir -p /app/sql_tpch
COPY sql_tpch/*.py /app/sql_tpch/

RUN mkdir -p /app/py_common
COPY py_common/*.py /app/py_common/

RUN pip install -r requirements.txt

# Environment configuration override as needed...
# ENV SQL_TPCH_RESULTS_ROOT /netstore/qa/jenkins/SqlScaleTest
# ENV SQL_TPCH_META_FILE_NAME .datasource.meta
# ENV SQL_TPCH_META_CACHE_TTL 300

