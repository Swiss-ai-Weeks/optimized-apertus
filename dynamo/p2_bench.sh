#!/usr/bin/env bash
# Benchmark the deployed profile with the four P3/P4 workloads.   ./p2_bench.sh C06[:seqs=128]
source "$(dirname "$0")/profile_lib.sh"
load_profile "${1:?usage: p2_bench.sh PROFILE[:seqs=N]}"
[[ -f "$RESULTS/$TAG/profile.json" ]] || die "Deploy first: ./p1_up.sh $1"
TOKENIZER=swiss-ai/Apertus-v1.5-8B        # identical tokenizer to the FP8 checkpoint; already cached
[[ -f "$RESULTS/.bench_env" ]] && { source "$RESULTS/.bench_env"; }
GOODPUT="time_to_first_token:$SLO_TTFT_MS inter_token_latency:$SLO_ITL_MS"
curl -sf "http://localhost:$FE_PORT/v1/models" >/dev/null || die "No server on :$FE_PORT — run ./p1_up.sh $1"

run_aiperf() {  # outdir, then workload-specific args
  local out=$1; shift
  if [[ ${CLIENT:-docker} == local ]]; then     # used only for offline testing of this script
    aiperf profile "$@" --artifact-dir "$RESULTS/$out" > "$RESULTS/$out/aiperf_stdout.txt" 2>&1
  else
    docker run --rm --network host -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" -v "$RESULTS:/results" "$CLIENT_IMAGE" \
      aiperf profile "$@" --artifact-dir "/results/$out" > "$RESULTS/$out/aiperf_stdout.txt" 2>&1
  fi
}

for WL in $WORKLOADS; do
  for C in $CONCURRENCIES; do
    OUT="$TAG/$WL/c$C"; mkdir -p "$RESULTS/$OUT"
    COMMON=(--model "$MODEL" --tokenizer "$TOKENIZER" --url "http://localhost:$FE_PORT" --endpoint-type chat --streaming
            --output-tokens-mean 256 --output-tokens-stddev 0 --extra-inputs ignore_eos:true
            --synthetic-input-tokens-stddev 0 --concurrency "$C" --random-seed 42 --ui-type none --goodput "$GOODPUT")
    N=$(( C*4 > 64 ? C*4 : 64 ))
    case $WL in
      chat)       ARGS=(--synthetic-input-tokens-mean 512  --request-count "$N" --warmup-request-count "$C"); DESCW="512 in / 256 out" ;;
      rag)        ARGS=(--synthetic-input-tokens-mean 1024 --shared-system-prompt-length 3072 --request-count "$N" --warmup-request-count "$C")
                  DESCW="3072 shared + 1024 unique = 4096 in / 256 out" ;;
      multiturn)  S=$(( C > 8 ? C : 8 ))
                  ARGS=(--synthetic-input-tokens-mean 512 --conversation-num "$S" --conversation-turn-mean 6 --conversation-turn-stddev 0
                        --conversation-turn-delay-mean 0 --request-count $((S*6)))
                  DESCW="$S sessions x 6 turns, +512 in per turn (history resent), 256 out" ;;
      longprompt) ARGS=(--synthetic-input-tokens-mean 6500 --request-count "$N" --warmup-request-count "$C"); DESCW="6500 in / 256 out" ;;
      *) die "Unknown workload $WL" ;;
    esac
    log "$TAG | $WL ($DESCW) | concurrency $C"
    if run_aiperf "$OUT" "${COMMON[@]}" "${ARGS[@]}" && [[ -f "$RESULTS/$OUT/profile_export_aiperf.json" ]]; then :
    else
      warn "aiperf failed for $OUT — see results/$OUT/aiperf_stdout.txt"
      curl -sf "http://localhost:$FE_PORT/v1/models" >/dev/null || die "Server on :$FE_PORT stopped responding during $OUT"
    fi
  done
done
ok "$TAG benchmark done"
