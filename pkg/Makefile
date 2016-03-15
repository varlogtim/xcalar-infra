


xcalar-release-trusty.deb:
	fpm -s dir -t deb --name xcalar-release --package $@ --version 1.0 --iteration 2 --deb-no-default-config-files --vendor 'Xcalar, Inc.' --description 'Xcalar APT Repo' --after-install xcalar-release-trusty/after-install.sh -C xcalar-release-trusty etc usr
