#!/usr/bin/env bash
# Remove ONLY this toolkit's profile containers (apx-*) and its private etcd/NATS.
source "$(dirname "$0")/common.sh"
ids=$(docker ps -aq --filter name='^apx-'); [[ -n $ids ]] && docker rm -f $ids >/dev/null
docker rm -f apertus-etcd apertus-nats >/dev/null 2>&1 || true
ok "profile containers removed"
