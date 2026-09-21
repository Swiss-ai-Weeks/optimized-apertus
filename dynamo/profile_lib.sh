#!/usr/bin/env bash
# Loads a profile spec:  NAME[:seqs=N][,bt=N][,conc=A+B+C]   e.g.  C06   C06:seqs=128
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_profile() {
  local spec=$1 name ovr pair k v
  name=${spec%%:*}; ovr=""; [[ $spec == *:* ]] && ovr=${spec#*:}
  [[ -f "$ROOT/profiles/$name.env" ]] || die "Unknown profile '$name' (available: $(ls "$ROOT/profiles" | grep -vE '^(common|p3_winner)' | sed 's/\.env$//' | tr '\n' ' '))"
  unset DESC PHASE KIND GPUS PREFILL_GPU DECODE_GPU PREFILL_MAX_NUM_SEQS PREFILL_MAX_NUM_BATCHED_TOKENS DECODE_MAX_NUM_SEQS DECODE_MAX_NUM_BATCHED_TOKENS
  set -a
  source "$ROOT/profiles/common.env"
  source "$ROOT/profiles/p3_winner.env"
  source "$ROOT/profiles/$name.env"
  set +a
  TAG=$name; PROFILE_NAME=$name
  if [[ -n $ovr ]]; then
    IFS=',' read -ra _pairs <<<"$ovr"
    for pair in "${_pairs[@]}"; do
      k=${pair%%=*}; v=${pair#*=}
      [[ -n $k && -n $v && $pair == *=* ]] || die "Bad override '$pair' (use seqs=N, bt=N, conc=A+B+C)"
      case $k in
        seqs) MAX_NUM_SEQS=$v ;;
        bt)   MAX_NUM_BATCHED_TOKENS=$v ;;
        conc) CONCURRENCIES=${v//+/ } ;;
        *) die "Unknown override '$k' (use seqs=, bt=, conc=)" ;;
      esac
      [[ $k == conc ]] || TAG="$TAG-$k$v"
    done
  fi
  [[ ${PHASE:-} == P4 && -z ${P3_WINNER:-} ]] && die "Phase-3 gate not decided: set P3_WINNER, P3_ROUTER, P3_MAX_NUM_SEQS in profiles/p3_winner.env"
  NGPU=$(wc -w <<<"$GPUS")
  [[ $KIND =~ ^(vllm|dynamo-agg|dynamo-disagg)$ ]] || die "Profile $name: KIND must be vllm | dynamo-agg | dynamo-disagg"
  [[ $KIND == vllm && $NGPU != 1 ]] && die "Profile $name: standalone vLLM profile must use exactly 1 GPU"
  [[ $KIND == dynamo-disagg && ( -z ${PREFILL_GPU:-} || -z ${DECODE_GPU:-} ) ]] && die "Profile $name: set PREFILL_GPU and DECODE_GPU"
  return 0
}
