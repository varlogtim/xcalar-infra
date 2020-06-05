FROM python:3.6

MAINTAINER Robert Stephens <rstephens@xcalar.com>

# Environment configuration override as needed...
ENV LOG_LEVEL="INFO"
ENV JENKINS_HOST="jenkins.int.xcalar.com"

# Must mount /opt/clang5 to container when run
# Caveat: Don't be over-specific and mount /opt/clang5/bin, or
#         some requirements will not be visible to the tools.
ENV CLANG_LLVM_COV_PATH="/opt/clang5/bin/llvm-cov"
ENV CLANG_LLVM_PROFDATA_PATH="/opt/clang5/bin/llvm-profdata"

WORKDIR /usr/src/app

# Context is set to xcalar-infra/ by dbuild
COPY py_common/jenkins_aggregators/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p ./sql_perf
COPY sql_perf ./sql_perf/

RUN mkdir -p ./ubm_perf
COPY ubm_perf ./ubm_perf/

RUN mkdir -p ./coverage
COPY coverage ./coverage/

RUN mkdir -p ./py_common
COPY py_common ./py_common/

CMD ["./py_common/jenkins_aggregators/update.py"]
