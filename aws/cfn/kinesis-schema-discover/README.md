## Kinesis Schema Discover

A cloudformation template and python script that uses
AWS KinesisAnalytics Service to infer the schema of a
given JSON/CSV on S3.


## Quick start

    $ make

Will build your local python virtualenv (in `.venv`), upload
`data.csv` to a temporary s3 object, call the Kinesis API and
store the result in `data.schema.json`.

You can try any other csv, just place it into the this foilder
and execute (for example, `mydata.csv`):

    $ make mydata.schema.json

To run the standalone tool on any object, first make sure you
have built and activated the virtual environment.

    $ make venv
    $ source .venv/bin/activate
    $ ./discover_schema.py s3://xcfield/foo/bar/baz.csv

The output is written to stdout.


## Lambda

To deploy the function to Lambda, make modifications to discover_schema/app.py and
run

    $ make sam
