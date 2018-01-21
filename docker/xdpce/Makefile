.PHONY: image stop run logs logsf xccli shell
all: image run

CONTAINER_IMAGE ?= xdpce:latest
CONTAINER_NAME  ?= xdpce
TZ ?= America/Los_Angeles
INSTALLER_PATH ?= /netstore/qa/Downloads/ReleaseCandidates/xcalar-1.2.3-RC4/20171024-3c9a47f4/prod/xcalar-1.2.3-1296-installer
DEFAULT_CFG_PATH ?= default.cfg

EXEC_INPUT := $(shell test -t 0 && echo "-i")
EXEC_TERMINAL ?= -t
EXEC_ARGS := $(EXEC_TERMINAL) $(EXEC_INPUT)

CONTAINER_ARGS_COMMON = --cap-add=ALL --cap-drop=MKNOD \
                 --security-opt seccomp:unconfined \
                 --ulimit core=0:0 \
                 --ulimit nofile=64960 \
                 --ulimit nproc=140960:140960 \
                 --ulimit memlock=-1:-1 \
                 --ulimit stack=-1:-1 \
                 --shm-size=10g \
                 --memory-swappiness=10 \
                 -e TZ=$(TZ) \
                 -e IN_DOCKER=1 \
                 -e XLRDIR=/opt/xcalar \
                 -e XCE_HTTP_PORT=8080 \
                 -e container=docker \
                 -v /var/run/docker.sock:/var/run/docker.sock \
                 --name $(CONTAINER_NAME) \
                 -p 8080:8080 -p 443:443 -p 5000:5000 -p 8000:8000 -p 8443:8443 \
                 -p 9090:9090 -p 8889:8889 -p 12124:12124 -p 18552:18552

INSTALLER_ARGS = $(CONTAINER_ARGS_COMMON) -v $(INSTALLER_PATH):/tmp/xcalarInstaller $(CONTAINER_IMAGE)
RUN_ARGS = $(CONTAINER_ARGS_COMMON)  $(CONTAINER_IMAGE)

image:
	docker build -t $(CONTAINER_IMAGE) .

stop:
	docker stop $(CONTAINER_NAME) 2>/dev/null || true

run: image stop clean
	docker run -d -t $(INSTALLER_ARGS)

strip-binaries: install
	docker exec $(EXEC_ARGS) $(CONTAINER_NAME) strip /opt/xcalar/bin/usrnode /opt/xcalar/bin/childnode \
		/opt/xcalar/bin/clistener /opt/xcalar/bin/listener /opt/xcalar/bin/licenseCheck \
		/opt/xcalar/bin/xccli /opt/xcalar/bin/xcMapRClient /opt/xcalar/bin/xcmgmtd /opt/xcalar/bin/xcmonitor

install: run
	docker exec $(EXEC_ARGS) $(CONTAINER_NAME) /tmp/xcalarInstaller --caddy --start

enforce-samplesize: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) bash -c "echo Constants.MaxInteractiveDataSize=1073741824 >> /etc/xcalar/default.cfg"

replace-hostname: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) sed -i 's/Node.0.IpAddr=.*/Node.0.IpAddr=127.0.0.1/' /etc/xcalar/default.cfg

replace-port: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) sed -i 's/8443/8080/' /etc/xcalar/Caddyfile

install-license: strip-binaries
	docker cp XcalarLic.key $(CONTAINER_NAME):/etc/xcalar/XcalarLic.key

createuser: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) mkdir -p /var/opt/xcalar/config/ && curl -4 -H "Content-Type: application/json" -X POST -d "{ \"defaultAdminEnabled\": true, \"username\": \"admin\", \"email\": \"admin@xyz.com\", \"password\": \"admin\" }" "http://127.0.0.1:12124/login/defaultAdmin/set"

disable-https: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) sed -i 's/https/http/' /etc/xcalar/Caddyfile

stop-xcalar:
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) /opt/xcalar/bin/xcalarctl stop-supervisor

start-xcalar:
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) /opt/xcalar/bin/xcalarctl start

restart: stop-xcalar start-xcalar

status:
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) /opt/xcalar/bin/xcalarctl status

commit:
	docker commit $(CONTAINER_NAME) $(CONTAINER_NAME)

save:
	docker save $(CONTAINER_NAME) | gzip > $(CONTAINER_NAME).tar.gz

runWithCfg: image stop clean
	docker run -d -t -v $(DEFAULT_CFG_PATH):/etc/xcalar/default.cfg $(INSTALLER_ARGS)

clean: stop
	docker rm -f $(CONTAINER_NAME) 2>/dev/null || true

logs:
	docker logs --tail=100 $(CONTAINER_NAME)

logsf:
	docker logs -f $(CONTAINER_NAME)

xccli:
	docker exec -ti $(CONTAINER_NAME) /opt/xcalar/bin/xccli

shell:
	docker exec -ti $(CONTAINER_NAME) /bin/bash -l

docker-image: run install strip-binaries install-license replace-hostname replace-port enforce-samplesize createuser disable-https restart commit save

run-xcalar: run install strip-binaries install-license replace-hostname replace-port createuser disable-https restart

run_xdpce:
	docker run -v /Volumes:/mnt/Volumes -v /Users:/mnt/Users -d -t --user xcalar $(RUN_ARGS) bash && docker exec -it --user xcalar xdpce /opt/xcalar/bin/xcalarctl start
