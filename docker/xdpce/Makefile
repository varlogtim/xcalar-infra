.PHONY: image stop run logs logsf xccli shell
all: image run

BUILD_NUMBER ?= latest # Jenkins env variable
#CONTAINER_IMAGE ?= xdpce:$(BUILD_NUMBER)
CONTAINER_IMAGE ?= xdpce
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
                 -e XCE_HTTP_PORT=8839 \
                 -e container=docker \
                 -v /var/run/docker.sock:/var/run/docker.sock \
                 --name $(CONTAINER_NAME) \
                 -p 8818:8818

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
		/opt/xcalar/bin/licenseCheck \
		/opt/xcalar/bin/xccli /opt/xcalar/bin/xcMapRClient /opt/xcalar/bin/xcmgmtd /opt/xcalar/bin/xcmonitor

install: run
	docker exec $(EXEC_ARGS) $(CONTAINER_NAME) /tmp/xcalarInstaller --caddy --start
    ifneq ($(XPE),)
		docker cp $(XLRDIR)/src/data/xem.cfg $(CONTAINER_NAME):/etc/xcalar/default.cfg
		docker cp $(XLRDIR)/src/data/XcalarLic.key $(CONTAINER_NAME):/etc/xcalar/XcalarLic.key
    endif

enforce-samplesize: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) bash -c "echo Constants.MaxInteractiveDataSize=1073741824 >> /etc/xcalar/default.cfg"

replace-hostname: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) sed -i 's/Node.0.IpAddr=.*/Node.0.IpAddr=127.0.0.1/' /etc/xcalar/default.cfg

replace-port: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) sed -i 's/8443/8818/' /etc/xcalar/Caddyfile

install-license: strip-binaries
	docker cp XcalarLic.key $(CONTAINER_NAME):/etc/xcalar/XcalarLic.key

createuser: install-license
	docker cp $(XLRINFRADIR)/docker/xpe/staticfiles/defaultAdmin.json $(CONTAINER_NAME):/var/opt/xcalar/config/defaultAdmin.json
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) chmod 600 /var/opt/xcalar/config/defaultAdmin.json

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
    ifneq ($(XPE),)
		docker tag $(CONTAINER_IMAGE):latest $(CONTAINER_IMAGE):$(BUILD_NUMBER)
    endif
	docker save $(CONTAINER_IMAGE) | gzip > $(CONTAINER_NAME).tar.gz

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

copyconfig:
	docker cp $(CONTAINER_NAME):/var/opt/xcalar/.ipython ./.ipython
	docker cp $(CONTAINER_NAME):/var/opt/xcalar/.jupyter ./.jupyter
	docker cp $(CONTAINER_NAME):/var/opt/xcalar/jupyterNotebooks ./jupyterNotebooks
	docker cp $(CONTAINER_NAME):/var/opt/xcalar/config/defaultAdmin.json defaultAdmin.json
	docker cp $(CONTAINER_NAME):/opt/xcalar/xcalar-gui ./xcalar-gui

docker-image: run install strip-binaries install-license replace-hostname replace-port enforce-samplesize createuser restart copyconfig commit save

run-xcalar: run install strip-binaries install-license replace-hostname replace-port createuser restart

run_xdpce:
	docker run -v /Volumes:/mnt/Volumes -v /Users:/mnt/Users -d -t --user xcalar $(RUN_ARGS) bash && docker exec -it --user xcalar xdpce /opt/xcalar/bin/xcalarctl start
