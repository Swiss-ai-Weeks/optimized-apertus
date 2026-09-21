#!/usr/bin/env bash
# PRIVATE etcd + NATS for this benchmark (own names + ports), so we never collide with
# or discover anything from other Dynamo stacks on the same node. Idempotent.
source "$(dirname "$0")/common.sh"
log "Starting private etcd (:$ETCD_PORT) + NATS (:$NATS_PORT)"
docker rm -f apertus-etcd apertus-nats >/dev/null 2>&1 || true
docker run -d --name apertus-etcd --network host quay.io/coreos/etcd:v3.5.21 \
  etcd --name apertus --data-dir /tmp/etcd \
       --listen-client-urls "http://127.0.0.1:$ETCD_PORT" --advertise-client-urls "http://127.0.0.1:$ETCD_PORT" \
       --listen-peer-urls "http://127.0.0.1:$ETCD_PEER_PORT" --initial-advertise-peer-urls "http://127.0.0.1:$ETCD_PEER_PORT" \
       --initial-cluster "apertus=http://127.0.0.1:$ETCD_PEER_PORT" >/dev/null
docker run -d --name apertus-nats --network host nats:2.10 -js -p "$NATS_PORT" >/dev/null
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$ETCD_PORT/health" | grep -q true && break
  (( i == 30 )) && { docker logs apertus-etcd | tail -20; die "private etcd not healthy on :$ETCD_PORT"; }
  sleep 1
done
ok "etcd healthy (:$ETCD_PORT)"
for i in $(seq 1 15); do
  (exec 3<>"/dev/tcp/127.0.0.1/$NATS_PORT") 2>/dev/null && break
  (( i == 15 )) && { docker logs apertus-nats | tail -20; die "private NATS not listening on :$NATS_PORT"; }
  sleep 1
done
ok "NATS listening (:$NATS_PORT)"
