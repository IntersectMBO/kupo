#!/usr/bin/env bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Run the preprod node and query its progress until the requested fraction is met.
# CONFDIR, RUNNER_TEMP and CARDANO_NODE_VERSION are required.
# SYNC_TIMEOUT_SECONDS defaults to 1800; maintenance runs allow longer catch-up.
set -euo pipefail
SYNC_LEVEL="${1:-1}"
if ! jq -en --arg level "$SYNC_LEVEL" '$level | tonumber | . >= 0 and . <= 1' >/dev/null; then
  echo "::error::Synchronization level must be between 0 and 1." >&2
  exit 1
fi

SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-1800}"
if [[ ! "$SYNC_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::SYNC_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi
sync_deadline=$((SECONDS + SYNC_TIMEOUT_SECONDS))
mkdir -p "$RUNNER_TEMP/ipc"

docker run -d --name cardano-node \
  -v "$RUNNER_TEMP/db-preprod:/db" \
  -v "$RUNNER_TEMP/ipc:/ipc" \
  -v "$CONFDIR:/config" \
  "ghcr.io/intersectmbo/cardano-node:$CARDANO_NODE_VERSION" run --config /config/config.json --database-path /db --socket-path /ipc/node.socket --topology /config/topology.json

# Let cleanup run after a later sync failure, but not before a node was started.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'node-started=true\n' >> "$GITHUB_OUTPUT"
fi

check_deadline() {
  if [ "$SECONDS" -ge "$sync_deadline" ]; then
    echo "::error::Timed out waiting for node to sync." >&2
    docker logs --tail 100 cardano-node >&2 || true
    exit 1
  fi
}

check_running() {
  if [ "$(docker inspect --format '{{.State.Running}}' cardano-node)" != true ]; then
    echo "::error::cardano-node stopped before reaching the sync target." >&2
    docker logs --tail 100 cardano-node >&2 || true
    exit 1
  fi
}

echo "Waiting for node socket..."
deadline=$((SECONDS + 900))
while [ ! -S "$RUNNER_TEMP/ipc/node.socket" ]; do
  check_running
  check_deadline
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::Timed out waiting for node socket." >&2
    docker logs --tail 100 cardano-node >&2 || true
    exit 1
  fi
  sleep 5
done

echo "Waiting for sync to reach $SYNC_LEVEL..."
query_failures=0
while true; do
  check_running
  check_deadline
  # docker exec bypasses the image's CLI wrapper, so supply the socket explicitly.
  if ! tip=$(docker exec cardano-node cardano-cli query tip --testnet-magic 1 --socket-path /ipc/node.socket); then
    query_failures=$((query_failures + 1))
    if [ "$query_failures" -ge 12 ]; then
      echo "::error::Twelve consecutive tip queries failed." >&2
      docker logs --tail 100 cardano-node >&2 || true
      exit 1
    fi
    sleep 5
    continue
  fi
  query_failures=0
  # A successful query can omit progress while the node is initializing.
  # Missing progress is not zero, even when the requested target is zero.
  if ! progress=$(jq -er '.syncProgress // empty | tonumber | select(. >= 0 and . <= 100)' <<< "$tip"); then
    echo "Waiting for node to report sync progress..." >&2
    sleep 5
    continue
  fi
  echo "Sync progress: ${progress}%"
  if jq -en --argjson progress "$progress" --argjson level "$SYNC_LEVEL" \
      '$progress >= ($level * 100)' >/dev/null; then
    echo "Reached target sync level"
    break
  fi
  sleep 30
done
