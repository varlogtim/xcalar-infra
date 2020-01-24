import sys
import io
import datetime
import json
import boto3
import zlib
import csv
import optparse

class Manifest:
    def __init__(self, bucket):
        self.bucket = bucket
        self.LOG_BUCKET = 'xclogs'
        self.client = boto3.client('s3')
        self.resource = boto3.resource('s3')

    def _gz_extract(self, in_stream):
        dec = zlib.decompressobj(32 + zlib.MAX_WBITS)  # offset 32 to skip the header
        for chunk in in_stream:
            yield dec.decompress(chunk)

    def _gz_txt_extract(self, in_stream):
        for rv in self._gz_extract(in_stream):
            if rv:
                bytesDecoded = rv.decode('utf-8', 'ignore').encode('utf-8')
                yield "".join(map(chr, bytesDecoded)).strip()

    def _get(self, bucket, key):
        obj = self.resource.Object(bucket, key)
        return obj.get()['Body'].read()

    def _prefix(self):
        dt = datetime.datetime.today().strftime('%Y-%m-')
        return 'inventory/{}/{}/{}'.format(self.bucket, self.bucket, dt)

    def fetch_keys(self):
        response = self.client.list_objects_v2(Bucket=self.LOG_BUCKET, Prefix=self._prefix())
        item = sorted(response['Contents'], key=lambda item: item['LastModified'])[-1]
        data = json.loads(self._get(self.LOG_BUCKET, item['Key']).decode("utf-8"))
        for ff in data["files"]:
            dgz = self._get(self.LOG_BUCKET, ff['key'])
            stream = io.BytesIO(dgz)
            for row in self._gz_txt_extract(stream):
                yield row

if __name__ == "__main__":
    parser = optparse.OptionParser()
    parser.add_option('-b', '--bucket', action="store", dest="bucket", help="bucket name")
    options, args = parser.parse_args()
    if options.bucket is None:
        parser.print_help(sys.stderr)
        sys.exit(1)

    manifest = Manifest(options.bucket);
    for key in manifest.fetch_keys():
        print(key)
