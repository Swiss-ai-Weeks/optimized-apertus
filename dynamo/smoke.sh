#!/usr/bin/env bash
# One correctness request with plain-string content (the format Apertus 1.5 expects).
source "$(dirname "$0")/common.sh"
MODEL_ID=$(curl -sf "http://localhost:$HTTP_PORT/v1/models" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])')
RESP=$(curl -sf "http://localhost:$HTTP_PORT/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\": \"$MODEL_ID\", \"max_tokens\": 80, \"temperature\": 0,
  \"messages\": [{\"role\":\"user\",\"content\":\"Name the four official languages of Switzerland.\"}]}") \
  || die "chat request failed"
python3 - "$RESP" <<'PY' || exit 1
import sys, json
r = json.loads(sys.argv[1]); t = (r["choices"][0]["message"].get("content") or "")
hits = sum(w in t.lower() for w in ["german", "french", "italian", "roman"])
print("     answer:", t.strip().replace("\n", " ")[:160])
sys.exit(0 if hits >= 3 else 1)
PY
