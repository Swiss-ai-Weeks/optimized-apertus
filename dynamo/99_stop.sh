#!/usr/bin/env bash
# Stops ONLY this kit's containers (never the node's own etcd/nats).
source "$(dirname "$0")/common.sh"
docker rm -f "$SRV" apertus-etcd apertus-nats >/dev/null 2>&1 || true
ok "stopped apertus-srv, apertus-etcd, apertus-nats"
