FROM python:3.6

MAINTAINER Robert Stephens <rstephens@xcalar.com>

# Environment configuration override as needed...
ENV LOG_LEVEL="INFO"

# TEST/DEBUG
#ENV MONGO_DB_NAME="aggregator_testing"
#ENV UPDATE_JOB_LIST="XCEFuncTest,SqlScaleTest"
# TEST/DEBUG

WORKDIR /usr/src/app

# Context is set to xcalar-infra/ by dbuild
COPY py_common/jenkins_aggregators/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p ./sql_stats
COPY sql_stats ./sql_stats/

RUN mkdir -p ./coverage
COPY coverage ./coverage/

RUN mkdir -p ./py_common
COPY py_common ./py_common/


CMD ["./py_common/jenkins_aggregators/update.py"]
