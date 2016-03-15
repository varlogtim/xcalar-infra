all: help


help:
	@echo 'download  - download repo files'
	@echo 'upload    - upload repo files (WARNING: files not in source are deleted!)'


download:
	mkdir -p ./apt ./patches ./rpm
	gsutil -m rsync -d -R gs://repo.xcalar.net/apt/ ./apt/
	gsutil -m rsync -d -R gs://repo.xcalar.net/patches/ ./patches/
	gsutil -m rsync -d -R gs://repo.xcalar.net/rpm/ ./rpm/


upload:
	gsutil -m rsync -d -R ./apt/ gs://repo.xcalar.net/apt/
	gsutil -m rsync -d -R ./patches/ gs://repo.xcalar.net/patches/
	gsutil -m rsync -d -R ./rpm/ gs://repo.xcalar.net/rpm/

