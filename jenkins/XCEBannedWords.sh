#!/bin/bash

FILES="$(git diff --name-only HEAD^ HEAD -- src/bin src/include src/misc src/lib/lib\* | egrep '\.(c|cpp|hpp|h)$')"
test -z "$FILES" && exit 0
found=0
for f in $FILES; do
  echo "=== $f ===="
  git diff -w --diff-filter=AM HEAD^ HEAD -- $f | grep '^\+' | sed -e 's,//.*$,,g' | egrep -v '^\+\+\+' | egrep "$REGEX"
  res=${PIPESTATUS[4]}
  if [ $res -eq 0 ]; then
     found=1
  fi
done

exit $found

git diff -w --diff-filter=AM HEAD^ HEAD -- $FILES | grep '^\+' | sed -e 's,//.*$,,g' > diff.txt
if egrep "$REGEX" diff.txt; then
   echo >&2 "Found a match, failing build!"
   exit 1
fi
exit 0

