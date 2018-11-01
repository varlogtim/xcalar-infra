.PHONY: image stop run logs logsf xccli shell
all: image run

CONTAINER_IMAGE ?= xdpce
CONTAINER_NAME  ?= xdpce
TARFILE_NAME ?= xdpce.tar.gz
TZ ?= America/Los_Angeles
INSTALLER_PATH ?= /netstore/qa/Downloads/ReleaseCandidates/xcalar-1.2.3-RC4/20171024-3c9a47f4/prod/xcalar-1.2.3-1296-installer
DEFAULT_CFG_PATH ?= default.cfg
CONFIG_DIR ?= /var/opt/xcalar/config
CLIENT_SECRET_DIR ?= /opt/xcalar/src/bin/sdk/xdp/xcalar/external
XPE_STATIC_FILES = $(XLRINFRADIR)/docker/xpe/staticfiles

# temporary for XPE;
# the gui required in the Docker needs to be built with --product=xdee option
# but no rpm installers exist which install GUI built in this manner.
# provide this option to swap out what gets installed in to the Docker with a custom gui before Docker image saved
# once rpm installers are generated which install this this product option, remove this option
CUSTOM_GUI ?=

GUI_DIR_IN_CONTAINER= /opt/xcalar/xcalar-gui

CADDY_PORT ?= 443
# port to expose outside the Docker container, to map to the Caddy port (if blank Docker will expose a random port)
CADDY_EXTERNAL_PORT ?=
PORT_MAPPING ?= -p $(CADDY_EXTERNAL_PORT):$(CADDY_PORT) # supply PORT_MAPPING="" if you dont want a port exposed for Caddy
DOCKER_EXTRA_ARGS ?=

EXEC_INPUT := $(shell test -t 0 && echo "-i")
EXEC_TERMINAL ?= -t
EXEC_ARGS := $(EXEC_TERMINAL) $(EXEC_INPUT)
XCALARCTL = docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) /opt/xcalar/bin/xcalarctl

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
                  $(PORT_MAPPING) \
                  $(DOCKER_EXTRA_ARGS) \
                 --name $(CONTAINER_NAME)

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
	# patch the requirejs that Jupyter relies on, to export require even if it exists
	# (which it will, when we are running XD in nwjs)
	docker cp $(CONTAINER_NAME):/opt/xcalar/lib/python3.6/site-packages/notebook/static/components/requirejs/require.js .
	cp $(XPE_STATIC_FILES)/require.js.patch .
	patch < require.js.patch
	docker cp require.js $(CONTAINER_NAME):/opt/xcalar/lib/python3.6/site-packages/notebook/static/components/requirejs/require.js
	rm require.js require.js.patch
	# client_secret.json with default admin creds will allow old Jupyter notebooks
	# to work in app without tokens.
	docker exec $(EXEC_ARGS) $(CONTAINER_NAME) bash -c "mkdir -p $(CLIENT_SECRET_DIR)"
	docker cp $(XPE_STATIC_FILES)/client_secret.json $(CONTAINER_NAME):$(CLIENT_SECRET_DIR)/client_secret.json
    endif

    ifneq ($(CUSTOM_GUI),)
	docker exec $(EXEC_ARGS) $(CONTAINER_NAME) rm -r $(GUI_DIR_IN_CONTAINER)
	docker cp $(CUSTOM_GUI) $(CONTAINER_NAME):$(GUI_DIR_IN_CONTAINER)
    endif

enforce-samplesize: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) bash -c "echo Constants.MaxInteractiveDataSize=1073741824 >> /etc/xcalar/default.cfg"

replace-hostname: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) sed -i 's/Node.0.IpAddr=.*/Node.0.IpAddr=127.0.0.1/' /etc/xcalar/default.cfg

install-license: strip-binaries
	docker cp XcalarLic.key $(CONTAINER_NAME):/etc/xcalar/XcalarLic.key

createuser: install-license
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) mkdir -p $(CONFIG_DIR)
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) chmod 0700 $(CONFIG_DIR)
	docker cp $(XPE_STATIC_FILES)/defaultAdmin.json $(CONTAINER_NAME):$(CONFIG_DIR)/defaultAdmin.json
	docker exec $(EXEC_ARGS) --user xcalar $(CONTAINER_NAME) chmod 600 $(CONFIG_DIR)/defaultAdmin.json

stop-xcalar:
	$(XCALARCTL) stop-supervisor

start-xcalar:
	$(XCALARCTL) start

restart: stop-xcalar start-xcalar

status:
	$(XCALARCTL) status

commit:
	docker commit $(CONTAINER_NAME) $(CONTAINER_NAME)

save:
    ifneq ($(XPE),)
	XCALAR_IMAGE_NAME=$(CONTAINER_IMAGE) bash -x ../xpe/scripts/tagxpe.sh create_xpe_tar $(CONTAINER_IMAGE):latest $(TARFILE_NAME)
    else
	docker save $(CONTAINER_IMAGE):latest | gzip > $(TARFILE_NAME)
    endif

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
	docker cp $(CONTAINER_NAME):$(CONFIG_DIR)/defaultAdmin.json defaultAdmin.json
	docker cp $(CONTAINER_NAME):$(GUI_DIR_IN_CONTAINER) ./xcalar-gui

docker-image: run install strip-binaries install-license replace-hostname enforce-samplesize createuser restart copyconfig commit save

run-xcalar: run install strip-binaries install-license replace-hostname createuser restart

run_xdpce:
	docker run -v /Volumes:/mnt/Volumes -v /Users:/mnt/Users -d -t --user xcalar $(RUN_ARGS) bash && $(XCALARCTL) start
