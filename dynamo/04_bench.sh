#!/usr/bin/env bash
# Same AIPerf sweep against whatever is running on HTTP_PORT.
source "$(dirname "$0")/common.sh"
MODE=${1:?usage: 04_bench.sh <mode>}
[[ -f "$RESULTS/.bench_env" ]] || die "Run 01_build.sh first"
source "$RESULTS/.bench_env"
MODEL_ID=$(curl -sf "http://localhost:$HTTP_PORT/v1/models" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])') \
  || die "No server on :$HTTP_PORT"

for SC in $SCENARIOS; do
  case "$SC" in
    chat) ISL=512;  OSL=256; EXTRA="" ;;
    rag)  ISL=4096; OSL=256; EXTRA="$PREFIX_ARGS" ;;
    *) die "unknown scenario $SC" ;;
  esac
  for C in $CONCURRENCIES; do
    OUT="$MODE/$SC/c$C"; mkdir -p "$RESULTS/$OUT"
    N=$(( C*8 > 64 ? C*8 : 64 ))
    log "$MODE | $SC (ISL $ISL / OSL $OSL) | concurrency $C | $N requests"
    running || die "server died during benchmark"
    # shellcheck disable=SC2086
    docker run --rm --network host -e HF_TOKEN \
      -v "$HF_CACHE:/root/.cache/huggingface" -v "$RESULTS:/results" "$CLIENT_IMAGE" \
      aiperf profile --model "$MODEL_ID" --tokenizer "$TOKENIZER" \
        --url "http://localhost:$HTTP_PORT" --endpoint-type chat --streaming \
        --synthetic-input-tokens-mean "$ISL" --synthetic-input-tokens-stddev 0 \
        --output-tokens-mean "$OSL" --output-tokens-stddev 0 --extra-inputs ignore_eos:true \
        --concurrency "$C" --request-count "$N" --warmup-request-count "$C" \
        --random-seed 42 --ui-type none $EXTRA \
        --artifact-dir "/results/$OUT" > "$RESULTS/$OUT/aiperf_stdout.txt" 2>&1 \
      || die "aiperf failed — see results/$OUT/aiperf_stdout.txt"
  done
done
ok "$MODE sweep done"
