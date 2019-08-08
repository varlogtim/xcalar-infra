FROM python:3.6

MAINTAINER Robert Stephens <rstephens@xcalar.com>

# Environment configuration override as needed...
ENV LOG_LEVEL=INFO

WORKDIR /usr/src/app

# Context is set to xcalar-infra/ by dbuild
COPY sql_tpch/update/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p ./sql_tpch
COPY sql_tpch/*.py ./sql_tpch/

RUN mkdir -p ./py_common
COPY py_common/*.py ./py_common/

COPY sql_tpch/update/sql_tpch_update.py ./
CMD ["./sql_tpch_update.py"]
