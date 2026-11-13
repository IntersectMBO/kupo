#!/usr/bin/env bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Save a stopped node's database and prune obsolete cached ledger snapshots.
# The workflow serializes writers across refs; CI jobs only restore this cache.
# Usage: preprod-db-save.sh s3://BUCKET/PREFIX DB_DIR

set -euo pipefail
# shellcheck source=.github/workflows/scripts/preprod-db-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/preprod-db-common.sh"
S3_DB_PATH="${1:-}"
DB_DIR="${2:-}"
check_cache_args
S3_DB_PATH="${S3_DB_PATH%/}"
DB_DIR="${DB_DIR%/}"
BASELINE_FILE="$DB_DIR.restored-chunks"

# Preserve partial synchronization progress only after an orderly shutdown.
# Neither a failed restore nor a truncated/unclean database may replace the cache.
for required in "$BASELINE_FILE" "$DB_DIR/protocolMagicId" "$DB_DIR/clean"; do
  if [ ! -f "$required" ]; then
    echo "::error::Missing $required; refusing to overwrite the cache." >&2
    exit 1
  fi
done
baseline=$(cat "$BASELINE_FILE")
[[ "$baseline" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || { echo "Invalid restore baseline" >&2; exit 1; }
chunks=$(find "$DB_DIR/immutable" -type f -name '*.chunk' | wc -l)
if [ "$chunks" -eq 0 ] || [ "$chunks" -lt "$baseline" ]; then
  echo "::error::Immutable chunk count is $chunks ($baseline restored); refusing to overwrite the cache." >&2
  exit 1
fi

local_names=
if [ -d "$DB_DIR/ledger" ]; then
  local_names=$(find "$DB_DIR/ledger" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
fi
local_snapshots=()
while IFS= read -r name; do
  if [[ "$name" =~ ^[0-9]+(_[A-Za-z0-9_-]+)?$ ]]; then local_snapshots+=("$name"); fi
done <<< "$local_names"
objects=$(cache_list "$S3_DB_PATH/ledger/")
cached_names=$(snapshot_names <<< "$objects")
objects=$(cache_list "$S3_DB_PATH/")

# Clear the old completion marker before any upload. Restore may run concurrently;
# this shared prefix is not an atomic snapshot, so never promise it is one.
if jq -e --arg key "$S3_DB_PATH/clean" 'any(.[]; .key == $key)' <<< "$objects" >/dev/null; then
  s5cmd --log error rm "$S3_DB_PATH/clean"
fi

echo "Saving $(du -sh "$DB_DIR" | cut -f1) to $S3_DB_PATH..."
# Immutable data is append-only; never delete cached chunks during publication.
s5cmd --log error sync "$DB_DIR/immutable/" "$S3_DB_PATH/immutable/"
for snapshot in "${local_snapshots[@]}"; do
  echo "Uploading ledger/$snapshot..."
  s5cmd --log error sync "$DB_DIR/ledger/$snapshot/" "$S3_DB_PATH/ledger/$snapshot/"
done
if [ -d "$DB_DIR/volatile" ]; then
  s5cmd --log error sync --delete "$DB_DIR/volatile/" "$S3_DB_PATH/volatile/"
fi
s5cmd --log error cp "$DB_DIR/protocolMagicId" "$S3_DB_PATH/protocolMagicId"

# Upload every retained snapshot before deleting any old one. An empty local
# ledger must not wipe the cached fallback snapshots.
if [ "${#local_snapshots[@]}" -gt 0 ]; then
  while IFS= read -r snapshot; do
    [ -n "$snapshot" ] || continue
    keep=false
    for local_snapshot in "${local_snapshots[@]}"; do
      if [ "$local_snapshot" = "$snapshot" ]; then keep=true; break; fi
    done
    if [ "$keep" = false ]; then
      echo "Pruning stale ledger/$snapshot..."
      s5cmd --log error rm "$S3_DB_PATH/ledger/$snapshot/*"
    fi
  done <<< "$cached_names"
fi
# Publish the clean marker only after all data transfers and pruning succeed.
s5cmd --log error cp "$DB_DIR/clean" "$S3_DB_PATH/clean"
echo "Save succeeded"
