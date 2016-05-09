TMP:=$(shell mktemp -u -d --tmpdir repoXXXXXX)

all: help


help:
	@echo 'download  - download repo files'
	@echo 'upload    - upload repo files (WARNING: files not in source are deleted!)'


download:
	mkdir -p ./apt ./patches ./rpm ./rpm-deps
	gsutil -m rsync -d -R gs://repo.xcalar.net/apt/ ./apt/
	gsutil -m rsync -d -R gs://repo.xcalar.net/patches/ ./patches/
	gsutil -m rsync -d -R gs://repo.xcalar.net/rpm/ ./rpm/
	gsutil -m rsync -d -R gs://repo.xcalar.net/rpm-deps/ ./rpm-deps/


upload:
	gsutil -m rsync -c -d -R ./apt/ gs://repo.xcalar.net/apt/
	gsutil -m rsync -c -d -R ./patches/ gs://repo.xcalar.net/patches/
	gsutil rm -R gs://repo.xcalar.net/rpm/el6/x86_64/repodata/ gs://repo.xcalar.net/rpm/el7/x86_64/repodata/
	gsutil -m rsync -c -d -R ./rpm/ gs://repo.xcalar.net/rpm/
	gsutil rm -R gs://repo.xcalar.net/rpm-deps/el6/x86_64/repodata/ gs://repo.xcalar.net/rpm-deps/el7/x86_64/repodata/
	gsutil -m rsync -c -d -R ./rpm-deps/ gs://repo.xcalar.net/rpm-deps/


xcalar-release-1.0-2.x86_64.rpm: pubkey.gpg rpm/xcalar.repo rpm-deps/xcalar-deps.repo
	mkdir -p $(TMP)/etc/pki/rpm-gpg $(TMP)/etc/yum.repos.d
	cp $< $(TMP)/etc/pki/rpm-gpg/RPM-GPG-KEY-Xcalar
	cp $(filter-out $<,$^) $(TMP)/etc/yum.repos.d/
	printf '#!/bin/sh\nrpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Xcalar || true\n' > $(TMP)/after.sh && chmod +x $(TMP)/after.sh
	fpm -s dir -t rpm -n xcalar-release \
        --url http://xcalar.com --description 'Xcalar Yum Repositories' \
        --maintainer info@xcalar.com --vendor 'Xcalar, Inc.' --license Proprietary \
        -v 1.0 --after-install $(TMP)/after.sh --iteration 2 -C $(TMP) etc
	rm -rf $(TMP)

