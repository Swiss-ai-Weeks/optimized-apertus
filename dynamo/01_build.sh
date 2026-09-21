#!/usr/bin/env bash
# Pull fork, build Dynamo-on-fork + client images, download weights, detect client capabilities.
source "$(dirname "$0")/common.sh"

log "Pulling Swiss AI vLLM fork image"
docker pull "$FORK_IMAGE"

log "Building $DYN_IMAGE (Dynamo on top of the fork; verifies the fork survives)"
docker build -f Dockerfile.dynamo --build-arg FORK_IMAGE="$FORK_IMAGE" --build-arg DYNAMO_VERSION="${DYNAMO_VERSION:-1.3.1}" -t "$DYN_IMAGE" .
docker run --rm "$DYN_IMAGE" bash -c 'diff /opt/pip_before.txt /opt/pip_after.txt || true' \
  > "$RESULTS/pip_diff_dynamo_install.txt"
ok "package changes from Dynamo install -> results/pip_diff_dynamo_install.txt"

log "Building $CLIENT_IMAGE (AIPerf)"
docker build -f Dockerfile.client -t "$CLIENT_IMAGE" .

log "Downloading weights into $HF_CACHE"
docker run --rm -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" --entrypoint hf \
  "$FORK_IMAGE" download "$MODEL" >/dev/null
ok "weights cached"

log "Detecting AIPerf options and tokenizer"
HELP=$(docker run --rm -e COLUMNS=400 "$CLIENT_IMAGE" aiperf profile --help 2>&1 | sed "s/\x1b\[[0-9;]*m//g" || true)
for f in --tokenizer --url --endpoint-type --streaming --synthetic-input-tokens-mean --output-tokens-mean \
         --concurrency --request-count --warmup-request-count --random-seed --artifact-dir --extra-inputs; do
  grep -q -- "$f" <<<"$HELP" || die "Installed aiperf lacks $f — check 'aiperf profile --help'"
done
PREFIX_ARGS=""
if   grep -q -- "--shared-system-prompt-length" <<<"$HELP"; then PREFIX_ARGS="--shared-system-prompt-length 3072"
elif grep -q -- "--prefix-prompt-length"        <<<"$HELP"; then PREFIX_ARGS="--prefix-prompt-length 3072 --prefix-prompt-pool-size 1"
else warn "aiperf has no shared-prefix option: 'rag' runs without a shared prefix (KV-router advantage will be understated)"; fi

TOKENIZER="$MODEL"
if ! docker run --rm -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" "$CLIENT_IMAGE" \
     python -c "from transformers import AutoTokenizer as T; T.from_pretrained('$MODEL')" >/dev/null 2>&1; then
  TOKENIZER="swiss-ai/Apertus-8B-Instruct-2509"
  warn "Stock transformers can't load the 1.5 tokenizer; client uses $TOKENIZER only to SIZE synthetic prompts (server-side counts unaffected)"
fi
printf 'PREFIX_ARGS="%s"\nTOKENIZER="%s"\n' "$PREFIX_ARGS" "$TOKENIZER" > "$RESULTS/.bench_env"
ok "client settings -> results/.bench_env"
log "Build complete"
