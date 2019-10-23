FROM tiangolo/uwsgi-nginx-flask:python3.6

MAINTAINER Robert Stephens <rstephens@xcalar.com>

# Environment configuration override as needed...
ENV LOG_LEVEL="DEBUG"
ENV JMQ_SERVICE_HOST="cvraman3.int.xcalar.com"
ENV JMQ_SERVICE_PORT="4000"

# Context is set to xcalar-infra/ by dbuild

COPY py_common/jenkins_meta_query/grafana/requirements.txt /app
RUN pip install --no-cache-dir -r requirements.txt

# Flask app needs to be in main.py for NGINX container
COPY py_common/jenkins_meta_query/grafana/main.py /app/main.py

RUN mkdir -p /app/py_common
COPY py_common /app/py_common/
