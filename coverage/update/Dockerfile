FROM python:3.6

MAINTAINER Robert Stephens <rstephens@xcalar.com>

# Environment configuration override as needed...
ENV LOG_LEVEL=INFO

WORKDIR /usr/src/app

# Context is set to xcalar-infra/ by dbuild
COPY coverage/update/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p ./coverage
COPY coverage/*.py ./coverage/

RUN mkdir -p ./py_common
COPY py_common/*.py ./py_common/

COPY coverage/update/coverage_update.py ./
CMD ["./coverage_update.py"]
