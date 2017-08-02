xdp-standard-package.zip: createUiDefinition.json applianceMainTemplate.json mainTemplate.json
	cp createUiDefinition.json applianceCreateUiDefinition.json
	zip xdp-standard-package.zip applianceCreateUiDefinition.json createUiDefinition.json applianceMainTemplate.json mainTemplate.json

.PHONY: all clean

all: xdp-standard-package.zip

clean:
	rm -f xdp-standard-package.zip applianceCreateUiDefinition.json 
