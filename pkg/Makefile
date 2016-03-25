all: xcalar-release-trusty.deb xcalar-release-el.rpm


xcalar-release-trusty.deb: xcalar-release-trusty/after-install.sh xcalar-release-trusty/usr/share/xcalar/gpg/pubkey.gpg xcalar-release-trusty/etc/apt/sources.list.d/xcalar.list
	fpm -s dir -t deb --name xcalar-release --package $@ --version 1.0 --iteration 2 --deb-no-default-config-files --vendor 'Xcalar, Inc.' --description 'Xcalar APT Repo' --after-install xcalar-release-trusty/after-install.sh -C xcalar-release-trusty etc usr
	gsutil cp $@ gs://repo.xcalar.net/

xcalar-release-el.rpm: xcalar-release-el/etc/yum.repos.d/xcalar.repo xcalar-release-el/etc/yum.repos.d/xcalar-deps.repo xcalar-release-el/etc/pki/rpm-gpg/RPM-GPG-KEY-Xcalar
	fpm -s dir -t rpm --name xcalar-release --package $@ --version 1.0 --iteration 2 --vendor 'Xcalar, Inc.' --description 'Xcalar YUM Repo' -C xcalar-release-el etc
	gsutil cp $@ gs://repo.xcalar.net/

