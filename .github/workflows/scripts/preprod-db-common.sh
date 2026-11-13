#!/usr/bin/env bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Helpers shared by the preprod database restore and save scripts.
# Requires s5cmd and jq. An empty prefix is different from a failed listing.

cache_list() {
  local prefix="$1" scratch rc=0
  scratch=$(mktemp -d)
  s5cmd --json ls "$prefix" > "$scratch/objects" 2> "$scratch/errors" || rc=$?
  if [ "$rc" -eq 0 ]; then
    jq -s '.' "$scratch/objects" || rc=$?
  elif jq -e -s 'length > 0 and all(.[]; .operation == "ls" and .error == "no object found")' \
      "$scratch/errors" >/dev/null 2>&1 && [ ! -s "$scratch/objects" ]; then
    printf '[]\n'
    rc=0
  else
    cat "$scratch/errors" >&2
  fi
  rm -rf -- "$scratch"
  return "$rc"
}

snapshot_names() {
  jq -r '.[] | select(.type == "directory") | .key | rtrimstr("/") | split("/") | last
         | select(test("^[0-9]+(_[A-Za-z0-9_-]+)?$"))'
}

check_cache_args() {
  if [[ ! "$S3_DB_PATH" =~ ^s3://[^/]+/.+ ]] || [[ "$S3_DB_PATH" == *[\*\?\[]* ]] \
      || [ -z "$DB_DIR" ] || [ "$DB_DIR" = / ]; then
    echo "Usage: $0 s3://BUCKET/PREFIX DB_DIR" >&2
    exit 1
  fi
}
