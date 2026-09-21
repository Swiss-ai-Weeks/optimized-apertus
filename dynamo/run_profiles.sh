#!/usr/bin/env bash
# Deploy -> verify -> benchmark -> tear down, for each profile in order; then the tokenomics report.
#   ./run_profiles.sh C04R C05 C06            (Phase 3)
#   ./run_profiles.sh C06:seqs=128 C06:seqs=256   (batch sweep on the P3 winner)
#   ./run_profiles.sh C07 C08 C08b            (Phase 4, back to back = same session)
source "$(dirname "$0")/profile_lib.sh"
(( $# )) || die "usage: ./run_profiles.sh PROFILE [PROFILE ...]   e.g. C04R C05 C06"
for spec in "$@"; do load_profile "$spec"; done          # validate every spec before starting anything
D="$(dirname "$0")"
for spec in "$@"; do
  "$D/p1_up.sh" "$spec"
  "$D/p2_bench.sh" "$spec"
  "$D/p3_down.sh"
done
log "Tokenomics report"
"$D/p4_tokenomics.py" "$RESULTS" | tail -40
tar czf "$ROOT/profiles_results_$(date +%Y%m%d_%H%M).tgz" -C "$(dirname "$RESULTS")" "$(basename "$RESULTS")"
log "Done — full report: results/tokenomics.md · raw: results/all_runs.csv · archive: profiles_results_*.tgz (copy it off the box)"
