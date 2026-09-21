#!/usr/bin/env bash
# Full pipeline. Re-runnable: skip build with SKIP_BUILD=1, restrict with MODES="dyn-1w dyn-2w-kv".
source "$(dirname "$0")/common.sh"
D="$(dirname "$0")"
"$D/00_preflight.sh"
[[ "${SKIP_BUILD:-0}" == 1 ]] || "$D/01_build.sh"
for M in $MODES; do
  "$D/03_start.sh" "$M"
  "$D/04_bench.sh" "$M"
  docker logs "$SRV" > "$RESULTS/$M/logs/container.log" 2>&1 || true
done
"$D/99_stop.sh"
log "Summarizing"
docker run --rm -e TTFT_SLO_MS -v "$RESULTS:/results" -v "$ROOT:/work:ro" "$CLIENT_IMAGE" \
  python /work/05_summarize.py /results
tar czf "$ROOT/results_$(date +%Y%m%d_%H%M).tgz" -C "$(dirname "$RESULTS")" "$(basename "$RESULTS")"
log "Done. Copy results_*.tgz off the LaunchPad box NOW (sessions are ephemeral)."
