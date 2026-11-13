#!/usr/bin/env bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Restore immutable data, the two newest ledger snapshots, and volatile data.
# Ledger downloads stay bounded even when the legacy cache contains old snapshots.
# The save script mirrors volatile data so it stops accumulating after the first save.
# Usage: preprod-db-restore.sh s3://BUCKET/PREFIX DB_DIR

set -euo pipefail
# shellcheck source=.github/workflows/scripts/preprod-db-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/preprod-db-common.sh"
S3_DB_PATH="${1:-}"
DB_DIR="${2:-}"
check_cache_args
S3_DB_PATH="${S3_DB_PATH%/}"
DB_DIR="${DB_DIR%/}"
BASELINE_FILE="$DB_DIR.restored-chunks"
mkdir -p "$DB_DIR"
rm -f -- "$BASELINE_FILE"
log=$(mktemp)
pid=
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -f -- "$log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

restore() {
  local objects snapshots snapshot marker markers
  objects=$(cache_list "$S3_DB_PATH/")
  if [ "$(jq 'length' <<< "$objects")" -eq 0 ]; then
    echo "Cache is empty; the node will sync from genesis."
    return 0
  fi
  # An inaccessible or partial cache must not be mistaken for a cold cache.
  if ! jq -e --arg key "$S3_DB_PATH/immutable/" 'any(.[]; .key == $key)' <<< "$objects" >/dev/null; then
    echo "::error::Cache contains data but no immutable directory." >&2
    return 1
  fi
  echo "Restoring immutable/..."
  s5cmd --log error sync "$S3_DB_PATH/immutable/*" "$DB_DIR/immutable/"

  objects=$(cache_list "$S3_DB_PATH/ledger/")
  snapshots=$(snapshot_names <<< "$objects" | sort -t_ -k1,1n | tail -2)
  if [ -z "$snapshots" ]; then
    echo "Cache holds no ledger snapshot; the node will replay the immutable chain."
  else
    while IFS= read -r snapshot; do
      echo "Restoring ledger/$snapshot..."
      s5cmd --log error sync "$S3_DB_PATH/ledger/$snapshot/*" "$DB_DIR/ledger/$snapshot/"
    done <<< "$snapshots"
  fi

  objects=$(cache_list "$S3_DB_PATH/volatile/")
  if [ "$(jq 'length' <<< "$objects")" -gt 0 ]; then
    echo "Restoring volatile/..."
    s5cmd --log error sync "$S3_DB_PATH/volatile/*" "$DB_DIR/volatile/"
  fi

  # Only missing objects are optional; permission and network errors must fail.
  objects=$(cache_list "$S3_DB_PATH/")
  markers=$(jq -r '.[] | select(.type == "file") | .key | split("/") | last' <<< "$objects")
  for marker in protocolMagicId clean; do
    rm -f -- "$DB_DIR/$marker"
    if grep -Fxq "$marker" <<< "$markers"; then
      s5cmd --log error cp "$S3_DB_PATH/$marker" "$DB_DIR/$marker"
    fi
  done
}

for attempt in 1 2 3; do
  echo "Restore attempt $attempt..."
  restore > "$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    # s5cmd renames temporary files while du walks the directory. Progress is
    # best-effort; only the restore process's exit status determines success.
    du -sh "$DB_DIR" 2>/dev/null || true
    sleep 15
  done
  rc=0
  wait "$pid" || rc=$?
  pid=
  echo "Restore attempt $attempt finished (exit $rc). Last 30 lines of log:"
  tail -30 "$log"
  if [ "$rc" -eq 0 ]; then break; fi
  if [ "$attempt" -eq 3 ]; then exit 1; fi
  echo "Retrying..."
done

chunks=0
if [ -d "$DB_DIR/immutable" ]; then
  chunks=$(find "$DB_DIR/immutable" -type f -name '*.chunk' | wc -l)
fi
printf '%s\n' "$chunks" > "$BASELINE_FILE"
echo "Restored $chunks immutable chunks, $(du -sh "$DB_DIR" | cut -f1) on disk."
